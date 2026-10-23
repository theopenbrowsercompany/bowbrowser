import Foundation

/// Chromium log lines that are known to be harmless. The run drops them before the `chromium.errors` check; every
/// other ERROR or FATAL line fails it. Each entry matches one log site's exact messages and says why they are benign.
/// Add an entry only for a message shown to be harmless, with its cause and evidence in its comment.
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

/// The context of unexpected lines, written to `chromium-errors.txt` so a rare error can be traced to its test and
/// teardown step from one failing run: the log lines around them, with overlapping stretches merged, and for each
/// stretch the nearest marks before and after it (see `E2EChromiumLog.mark`).
enum E2EChromiumErrorContext {
    static let fileName = "chromium-errors.txt"
    /// Log lines kept before and after each unexpected line.
    static let radius = 20
    /// Stretches written; a run with more says how many unexpected lines it left out.
    static let maxStretches = 10

    /// `lines` is the whole log; `unexpected` and `marks` are the indexes of its unexpected lines and marks, in order.
    static func text(lines: [Substring], unexpected: [Int], marks: [Int]) -> String {
        // Each stretch is a range of lines and the unexpected lines in it.
        var stretches: [(range: ClosedRange<Int>, unexpected: [Int])] = []
        for index in unexpected {
            let range = max(0, index - radius)...min(lines.count - 1, index + radius)
            if let last = stretches.last, range.lowerBound <= last.range.upperBound + 1 {
                stretches[stretches.count - 1] = (last.range.lowerBound...range.upperBound, last.unexpected + [index])
            } else {
                stretches.append((range, [index]))
            }
        }
        var text = ""
        for (number, stretch) in stretches.prefix(maxStretches).enumerated() {
            let before = marks.last { $0 < stretch.unexpected[0] }.map { String(lines[$0]) } ?? "none"
            let after =
                marks.first { $0 > stretch.unexpected[stretch.unexpected.count - 1] }
                .map { String(lines[$0]) } ?? "none"
            text += "== stretch \(number + 1) of \(stretches.count): \(stretch.unexpected.count) unexpected lines\n"
            text += "mark before: \(before)\nmark after: \(after)\n"
            for line in lines[stretch.range] {
                text += line + "\n"
            }
            text += "\n"
        }
        let left = stretches.dropFirst(maxStretches).reduce(0) { $0 + $1.unexpected.count }
        if left > 0 {
            text += "\(left) more unexpected lines are not shown\n"
        }
        return text
    }
}

/// Collects everything the app and its Chromium helpers write to stderr in `<run>/chromium.log`, so Chromium's log
/// stays with the run (also after a timeout or a crash) and the terminal only shows what matters.
/// After the engine has shut down, `finish()` reads the file back: it echoes every line that is not a Chromium log
/// line (for example `quit: seconds=`) and every ERROR or FATAL line that is not known to be harmless.
/// A run that times out echoes the same lines from the watchdog (`report()`), and when the app ends without an
/// `E2E:` line (a crash or a failed engine start) `make e2e` prints the end of the file itself.
final class E2EChromiumLog: Sendable {
    static let fileName = "chromium.log"
    /// Starts the lines `mark(_:)` writes, which `report()` neither echoes nor checks.
    static let markPrefix = "E2E MARK "
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

    /// Writes `E2E MARK <time> <text>` into the log on a line of its own, with the time in the format of Chromium's
    /// log lines (`MMDD/HHMMSS.microseconds`), so `chromium-errors.txt` can say which test step an error came during.
    /// Newlines in `text` become spaces. Safe to call from any thread.
    func mark(_ text: String) {
        var now = timeval()
        gettimeofday(&now, nil)
        var seconds = now.tv_sec
        var local = tm()
        localtime_r(&seconds, &local)
        let time = String(
            format: "%02d%02d/%02d%02d%02d.%06d", local.tm_mon + 1, local.tm_mday, local.tm_hour, local.tm_min,
            local.tm_sec, Int32(now.tv_usec))
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        // stderr is the log, opened with O_APPEND, so one write(2) lands whole. The leading newline starts the mark
        // on its own line even after a helper's unfinished line; the scan drops the empty line it can leave.
        Self.writeAll("\n\(Self.markPrefix)\(time) \(oneLine)\n", to: STDERR_FILENO)
    }

    /// Waits for Chromium's helpers to exit, then reports the log (see `report()`). Call it after the engine has shut
    /// down.
    func finish() -> E2EChromiumLogReport {
        Self.waitForHelpersToExit()
        return report()
    }

    /// Echoes the lines described above to the original stderr and returns what the scan found. When there are
    /// unexpected lines, it also writes their context to `chromium-errors.txt` next to the log.
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
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        let isMark = { (line: Substring) in line.hasPrefix(Self.markPrefix) }
        var unexpectedIndexes: [Int] = []
        var markIndexes: [Int] = []
        for (index, line) in lines.enumerated() {
            guard !isMark(line) else {
                markIndexes.append(index)
                continue
            }
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
                    unexpectedIndexes.append(index)
                    echo += line + "\n"
                }
            default:
                break
            }
        }
        Self.writeAll(echo, to: terminal)
        if !unexpectedIndexes.isEmpty {
            let context = E2EChromiumErrorContext.text(lines: lines, unexpected: unexpectedIndexes, marks: markIndexes)
            let contextURL = url.deletingLastPathComponent().appendingPathComponent(E2EChromiumErrorContext.fileName)
            try? context.write(to: contextURL, atomically: true, encoding: .utf8)
        }
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
    private static func writeAll(_ text: String, to file: Int32) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { return }
            bytes = bytes.dropFirst(written)
        }
    }
}
