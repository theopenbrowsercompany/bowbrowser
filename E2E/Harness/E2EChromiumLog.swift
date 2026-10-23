import Foundation

/// Chromium log lines that are known to be harmless. The run drops them before the `chromium.errors` check; every
/// other ERROR or FATAL line fails it. Each entry matches one log site's exact messages and says why they are benign.
/// Regex literals, so a broken entry fails the build instead of the run.
enum E2EKnownChromiumLines {
    static var patterns: [Regex<Substring>] {
        [
            // Logged together with the next entry. When a browser closes, Chromium's ProcessPriorityPolicy lowers
            // its renderer's priority on the process launcher thread; when the renderer has already exited, the
            // kernel rejects the call. Chromium skips exited processes it knows about, so this is its own race,
            // and setting the priority of a process that is gone does nothing. Seen at quit with two windows and,
            // under load, with one; it goes away with --disable-features=PMProcessPriorityPolicy. The kernel
            // answers "invalid argument" while the exited task's port still exists and "invalid destination port"
            // once it is gone; both come from the same call.
            #/\[[^\]]*:ERROR:base/process/process_mac\.cc:\d+\] task_policy_set TASK_CATEGORY_POLICY: (?:\(os/kern\) invalid argument \(4\)|\(ipc/send\) invalid destination port \(0x10000003\))/#,
            // The second half of the same priority change (see the entry above).
            #/\[[^\]]*:ERROR:base/process/process_mac\.cc:\d+\] task_policy_set TASK_SUPPRESSION_POLICY: (?:\(os/kern\) invalid argument \(4\)|\(ipc/send\) invalid destination port \(0x10000003\))/#,
            // Logged by the GPU process, together with the next entry, when a tab that was never shown closes
            // (tabs.close-window closes two such tabs, opened in the background). CEF creates a windowed browser's
            // page as visible, and Chromium ignores "hidden" until a page has been visible for real, in a window, so
            // a tab created in the parking view stays visible and keeps drawing into a layer in no window until it
            // is shown. Closing it destroys its page while its compositor still draws a frame, which then refers to
            // an image that is gone: Chromium leaves that overlay out of the frame (GetOrCreateOverlayData returns
            // no overlay) and draws the rest. That frame belongs to a browser being destroyed, in no window, so
            // nothing on screen changes. It comes right before the first such tab's OnBeforeClose in about two
            // runs of tabs.close-window in five, and never in 30 runs once each tab had been shown before closing.
            #/\[[^\]]*:ERROR:gpu/command_buffer/service/shared_image/shared_image_manager\.cc:\d+\] SharedImageManager::ProduceOverlay: Trying to Produce a Overlay representation from a non-existent mailbox\./#,
            // The second line of the same pair (see the entry above), from the compositor that asked for the image.
            #/\[[^\]]*:ERROR:components/viz/service/display_embedder/skia_output_device_buffer_queue\.cc:\d+\] Invalid mailbox\./#,
        ]
    }

    /// TEMPORARY: lines whose cause is not known yet, dropped only so the run stays usable while a separate work
    /// item investigates them. They are counted apart (`temporary=` in the `chromium.errors` line) so they stay
    /// visible. Remove each entry once its cause is found and fixed, or move it to `patterns` with evidence that
    /// it is harmless.
    static var temporaryPatterns: [Regex<Substring>] {
        []
    }
}

/// What a scan of chromium.log found: the unexpected ERROR and FATAL lines and how many known and temporary lines
/// it dropped.
struct E2EChromiumLogReport {
    var unexpected: [String] = []
    var known = 0
    var temporary = 0
}

/// Collects everything the app and its Chromium helpers write to stderr in `<run>/chromium.log`, so Chromium's log
/// stays with the run (also after a timeout or a crash) and the terminal only shows what matters.
/// After the engine has shut down, `finish()` reads the file back: it echoes every line that is not a Chromium log
/// line (for example `quit: seconds=`) and every ERROR or FATAL line that is not known to be harmless.
/// A run that times out echoes the same lines from the watchdog (`report()`), and when the app ends without an
/// `E2E:` line (a crash or a failed engine start) `make e2e` prints the end of the file itself.
final class E2EChromiumLog: Sendable {
    static let fileName = "chromium.log"
    /// How long `finish()` waits for Chromium's helpers to exit, so their last lines are in the file.
    static let helperExitTimeout: TimeInterval = 2

    let url: URL
    /// The stderr the app was started with, where echoed lines go.
    private let terminal: Int32

    /// Points this process's stderr at `url`. Call it before Chromium starts, so its helpers inherit the file.
    init(url: URL) throws {
        let file = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw E2EError("cannot write \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(file) }
        // Close on exec, so helpers hold only the log file and never the terminal.
        let original = fcntl(STDERR_FILENO, F_DUPFD_CLOEXEC, 0)
        guard original >= 0, dup2(file, STDERR_FILENO) >= 0 else {
            if original >= 0 { close(original) }
            throw E2EError("cannot send stderr to \(url.path): \(String(cString: strerror(errno)))")
        }
        self.url = url
        terminal = original
        // A terminal that has gone away (for example `make e2e | head`) must not end the run with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Waits for Chromium's helpers to exit, then reports the log (see `report()`). Call it after the engine has shut
    /// down.
    func finish() -> E2EChromiumLogReport {
        Self.waitForHelpersToExit()
        return report()
    }

    /// Echoes the lines described above to the original stderr and returns what the scan found.
    /// Safe to call from any thread.
    func report() -> E2EChromiumLogReport {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return E2EChromiumLogReport(unexpected: ["\(url.path) could not be read"])
        }
        let known = E2EKnownChromiumLines.patterns
        let temporary = E2EKnownChromiumLines.temporaryPatterns
        let severity = #/[\[:](VERBOSE\d*|INFO|WARNING|ERROR|FATAL):[^\]\s]+\] /#
        var result = E2EChromiumLogReport()
        var echo = ""
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            // Searched anywhere in the line, so a log line that another process's output ran into still counts.
            switch line.firstMatch(of: severity)?.output.1 {
            case nil:
                echo += line + "\n"
            case "ERROR", "FATAL":
                if known.contains(where: { line.contains($0) }) {
                    result.known += 1
                } else if temporary.contains(where: { line.contains($0) }) {
                    result.temporary += 1
                } else {
                    result.unexpected.append(String(line))
                    echo += line + "\n"
                }
            default:
                break
            }
        }
        writeToTerminal(echo)
        return result
    }

    /// Waits, up to `helperExitTimeout`, until the app's helpers have exited. Two kinds of child do not count:
    /// exited ones that Chromium no longer reaps after shutdown (zombies), which hold no files, and the code sign
    /// clone cleanup helper, which only deletes a temporary copy of the app and can outlive the app by seconds.
    private static func waitForHelpersToExit() {
        let deadline = Date(timeIntervalSinceNow: helperExitTimeout)
        while hasRunningHelpers() && Date() < deadline {
            usleep(20_000)
        }
    }

    private static func hasRunningHelpers() -> Bool {
        BowChildProcess.childrenOfCurrentProcess().contains { child in
            guard !child.arguments.contains("--type=code-sign-clone-cleanup") else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // A child that is gone by now reads as size 0 and counts as exited.
            return proc_pidinfo(child.pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_status != SZOMB
        }
    }

    /// Writes with write(2), which reports a closed terminal as an error instead of raising an exception.
    private func writeToTerminal(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(terminal, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return }
            bytes = bytes.dropFirst(written)
        }
    }
}
