import AppKit
import BowCore

/// Runs e2e tests inside the real app (`Bow --e2e=<selection> --e2e-out=<folder>`).
///
/// A selection is `all`, `list` (prints one `TEST` line per test and exits 0 without starting the engine), or a
/// comma separated list of test names, areas, globs and tags (see `E2ETests.select`).
///
/// The run uses a throwaway Chromium root and UserDefaults suite, an off-screen window that never takes focus,
/// no network and fixture pages at `https://bow.test/`. Each test gets a fresh in-memory profile, and once it ends
/// the runner closes its windows and checks that no browser is left (`e2e.isolation`). The test that checks
/// quitting runs last, with only its own window open.
///
/// It prints one `PASS name` or `FAIL name: reason` line per check, every check a test declares counted even when
/// the test stopped before reaching it, then one `RESULT <test> pass|fail|timeout seconds=<s> checks=<p>/<n>`
/// line per test, and a final `E2E: PASS n/n` (or `E2E: FAIL passed/n`) line, to stdout and `<folder>/report.txt`.
/// A step that runs past its limit fails its test (`TIMEOUT` in the reason) and the run goes on. A failing test
/// leaves `<folder>/<test>/fail.png` and `<folder>/<test>/log.txt`. The last test leaves `<folder>/final.png`.
/// Only a main thread that stops answering ends the run early, with `E2E: TIMEOUT` and a stack sample (see
/// `E2EWatchdog`).
/// Everything the app and Chromium write to stderr goes to `<folder>/chromium.log`; after the engine shuts down the
/// run echoes what matters from it and checks it for unexpected Chromium errors (`chromium.errors`).
/// Exit codes: 0 when every check passed, 1 when one failed, 2 when the run was ended by the watchdog.
@MainActor
final class E2ERunner {
    static let failureExitCode: Int32 = 1
    /// Generous, because parallel builds in other worktrees can starve Chromium's start.
    static let engineStartTimeout: TimeInterval = 60
    /// Quitting is checked against its own limit; this only stops a quit that hangs.
    /// It must fire well before Chromium's own teardown watchdog (`shutdown_watchdog_mac.cc`), which ends the
    /// process with exit code 2 and no summary ("Teardown watchdog expired") when Chromium's shutdown has not
    /// finished 10 seconds after its teardown began (`BrowserProcessImpl::StartTearDown`, inside `CefShutdown`, so
    /// always after the quit start timed here). Firing at 6 seconds prints the TIMEOUT line, the run's summary, at
    /// once; the stack sample and the Chromium log report then usually finish in the 4 seconds left, and if
    /// Chromium ends the process first the summary still stands. It stays above the quit check's own limit
    /// (`stoppingWithin`, checked in `expectQuit`), so a quit slower than that check still reports its times.
    static let quitHangTimeout: TimeInterval = 6
    /// While tests run, the run ends only when the main thread has not answered for this long.
    static let mainThreadStuckTimeout: TimeInterval = 10
    static let heartbeatInterval: TimeInterval = 0.25
    /// How long closing a test's windows may take before what is left counts as left over.
    static let cleanupTimeout: TimeInterval = 5
    /// The file that marks a folder as an e2e run folder, which a later run may reuse.
    static let runMarkerName = ".bow-e2e-run"
    /// A screenshot slower than this is given up, without failing the run.
    static let screenshotTimeout: TimeInterval = 10
    /// The selection that lists the tests instead of running them.
    static let listSelection = "list"
    /// The run-level check that every test left no window or browser open.
    static let isolationCheck = "e2e.isolation"
    /// The run-level check that Chromium logged no unexpected errors.
    static let chromiumErrorsCheck = "chromium.errors"

    let engineConfiguration: BowEngineConfiguration

    private let tests: [any E2ETest]
    fileprivate let profileDirectory: URL
    private let runDirectory: URL
    /// The run's downloads folder, emptied at the start of each run, so no download reaches the real one.
    fileprivate let downloadsDirectory: URL
    private let fixtureDirectory: URL
    private let defaultsSuiteName: String
    private let output: E2EOutput
    private let watchdog: E2EWatchdog
    private let chromiumLog: E2EChromiumLog
    private var checks: [(name: String, passed: Bool)] = []
    private var quitCheck: (name: String, closeLimit: TimeInterval, stopLimit: TimeInterval)?
    /// The error of a quit test that failed after expecting quit, which fails the quit check.
    private var quitFailure: String?
    /// The test running now, which the heartbeat names if the main thread gets stuck.
    private var activeRun: E2ERun?
    private var heartbeat: Timer?
    /// How many checks the tests themselves recorded (not e2e.isolation, the quit check or chromium.errors).
    private var testCheckCount = 0

    /// Prepares a run before the engine starts. Throws for an unknown test or an unusable output folder.
    init(options: LaunchOptions) throws {
        guard let selection = options.e2eTest, let outputPath = options.e2eOutput else {
            throw E2EError("not an e2e run")
        }
        try E2ETests.checkUnique()
        if selection == Self.listSelection {
            Self.list()
            exit(0)
        }
        tests = Self.quitTestLast(try E2ETests.select(selection))

        let fileManager = FileManager.default
        var runDirectory = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        // The run deletes <out>/profile, so it only reuses a folder an earlier run made (and marked).
        let marker = runDirectory.appendingPathComponent(Self.runMarkerName)
        if fileManager.fileExists(atPath: runDirectory.path) && !fileManager.fileExists(atPath: marker.path) {
            throw E2EError(
                "--e2e-out=\(outputPath) already exists and was not made by an e2e run; "
                    + "give a new folder (make e2e uses build/e2e/<run>)"
            )
        }
        do {
            try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: marker.path, contents: Data("Made by a Bow e2e run.\n".utf8)) else {
                throw E2EError("cannot write \(marker.path)")
            }
            // Chromium needs the real path: with a symlink in it (/tmp, a linked checkout) it silently keeps the
            // profile in memory. Resolve it once the folder exists.
            // (resolvingSymlinksInPath would turn /private/tmp back into /tmp, so use realpath.)
            if let realPath = realpath(runDirectory.path, nil) {
                runDirectory = URL(fileURLWithPath: String(cString: realPath), isDirectory: true)
                free(realPath)
            }
            profileDirectory = runDirectory.appendingPathComponent("profile", isDirectory: true)
            if fileManager.fileExists(atPath: profileDirectory.path) {
                try fileManager.removeItem(at: profileDirectory)
            }
            try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            downloadsDirectory = runDirectory.appendingPathComponent("downloads", isDirectory: true)
            if fileManager.fileExists(atPath: downloadsDirectory.path) {
                try fileManager.removeItem(at: downloadsDirectory)
            }
        } catch {
            throw E2EError("cannot prepare \(runDirectory.path): \(error.localizedDescription)")
        }
        guard let fixtures = Bundle.main.resourceURL?.appendingPathComponent("Fixtures", isDirectory: true),
            fileManager.fileExists(atPath: fixtures.path)
        else {
            throw E2EError("the app bundle has no Fixtures folder")
        }

        fixtureDirectory = fixtures
        self.runDirectory = runDirectory
        // Last, so a run that cannot start still reports why on the terminal.
        let chromiumLog = try E2EChromiumLog(url: runDirectory.appendingPathComponent(E2EChromiumLog.fileName))
        self.chromiumLog = chromiumLog
        output = E2EOutput(reportURL: runDirectory.appendingPathComponent("report.txt"))
        // A run that times out still shows its stderr and unexpected Chromium errors on the terminal.
        watchdog = E2EWatchdog(output: output, sampleURL: runDirectory.appendingPathComponent("hang.txt")) {
            _ = chromiumLog.report()
        }
        watchdog.setPending(tests.map(\.name))
        Self.removeStaleDefaultsSuites()
        defaultsSuiteName = Self.defaultsSuitePrefix + String(ProcessInfo.processInfo.processIdentifier)

        let configuration = BowEngineConfiguration(rootDataDirectory: profileDirectory.path)
        configuration.keychainServiceName = "Bow E2E Safe Storage"
        configuration.reportsQuitTime = true
        configuration.extraSwitches = [
            // Keep pages running and painting in a window no one can see.
            "disable-renderer-backgrounding": "",
            "disable-backgrounding-occluded-windows": "",
            "disable-background-timer-throttling": "",
            "disable-features": "MacWebContentsOcclusion",
            // No updates, first run work or network of any kind; fixtures are served without DNS, except the
            // loopback fixtures' two hosts, which resolve to their listeners on 127.0.0.1 (the first rule that
            // matches a host wins).
            "disable-component-update": "",
            "disable-background-networking": "",
            "no-first-run": "",
            "no-proxy-server": "",
            "host-resolver-rules": E2ELoopback.start() + "MAP * ~NOTFOUND",
            // The same colors and language on every machine.
            "force-color-profile": "srgb",
            "lang": "en-US",
            // Pages that ask for the camera or microphone get Chromium's fake devices, never the real ones, so no
            // macOS privacy prompt can show.
            "use-fake-device-for-media-stream": "",
        ]
        engineConfiguration = configuration

        AppSettings.defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        DownloadSettings.folder = downloadsDirectory
        // Never restore windows from an earlier run, and never show in the Dock or take focus.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        watchdog.arm("engine.start", timeout: Self.engineStartTimeout)
    }

    /// Called once the app has installed its handler for links from other apps, the first moment a link can reach
    /// it and before the first test: delivers the selected tests' early links (`E2EEarlyLinksTest`).
    func linkHandlerInstalled(delegate: AppDelegate) {
        E2EAppAdapter.deliverEarlyLinks(of: tests.compactMap { $0 as? any E2EEarlyLinksTest }, delegate: delegate)
    }

    /// Runs the tests once the engine has started, then quits.
    func start(delegate: AppDelegate) {
        watchdog.disarm()
        BowFixtureServer.serveDirectory(fixtureDirectory.path)
        BowPopupParking.start()
        let app = E2EAppAdapter(
            delegate: delegate, seedFolder: profileDirectory.appendingPathComponent("seeds", isDirectory: true))
        Task {
            startHeartbeat()
            var leftovers: [String] = []
            for (index, test) in tests.enumerated() {
                watchdog.setPending(tests[(index + 1)...].map(\.name))
                if let leftover = await run(test, index: index, isLast: index == tests.count - 1, app: app) {
                    leftovers.append("\(test.name): \(leftover)")
                }
            }
            testCheckCount = checks.count
            // The quit test keeps its window for quitting, so it is not among the tests checked here.
            let closed = tests.filter { !$0.quitsApp }.count
            if leftovers.isEmpty {
                record(Self.isolationCheck, passed: true, detail: "closed-tests=\(closed) left-over=0")
            } else {
                record(Self.isolationCheck, passed: false, detail: leftovers.joined(separator: "; "))
            }
            stopHeartbeat()
            watchdog.arm(quitCheck?.name ?? "app.quit", timeout: Self.quitHangTimeout)
            chromiumLog.mark("quitting")
            app.quit()
        }
    }

    /// Runs one test with its own profile and limit, fills in the checks it never reached, saves evidence when it
    /// failed, closes its windows and prints its RESULT line. Returns what the test left open, if anything.
    private func run(_ test: any E2ETest, index: Int, isLast: Bool, app: E2EAppAdapter) async -> String? {
        let run = E2ERun(runner: self, test: test, app: app.beginTest(index: index))
        activeRun = run
        beat()
        defer { activeRun = nil }
        chromiumLog.mark("start \(test.name)")
        let baseline = app.openBrowserCount
        let started = Date()

        let result = await E2ERace.run(
            timeout: E2ERun.testTimeout,
            timeoutError: E2EError(
                "TIMEOUT: the test ran past its \(Int(E2ERun.testTimeout)) s limit", reason: .timeout)
        ) {
            try await test.run(run)
        }
        let failure: (step: String, error: Error)?
        if case .failure(let error) = result { failure = (run.currentStep, error) } else { failure = nil }
        let checksBefore = run.firstCheck
        run.finish()
        // Work the test left running (a timed-out step) can no longer drive the app.
        app.endTest()
        // A held download the test did not release (it failed or timed out first) ends now, so its tab's parked
        // browser can close below and nothing waits on it into the next test.
        E2EFixture.releaseAllHeld()

        let missing = test.checks.filter { !run.recorded.contains($0) }
        if let failure {
            if missing.isEmpty {
                // Every check was recorded, so the error fails the last one rather than adding a check, which
                // would make the total depend on how far tests got. The RESULT line names the error too.
                let detail = "\(failure.step): \(failure.error) (after the check was recorded)"
                let recorded = checks[checksBefore...].map(\.name)
                if let last = test.checks.last(where: recorded.contains) {
                    fail(last, after: checksBefore, detail: detail)
                } else if test.quitsApp, quitCheck != nil {
                    // The quit check is reported after the engine stops; it fails then.
                    quitFailure = detail
                }
            }
            for (offset, check) in missing.enumerated() {
                let detail =
                    offset == 0 ? "\(failure.step): \(failure.error)" : "not run: the test stopped at \(failure.step)"
                record(check, passed: false, detail: detail)
            }
        } else {
            for check in missing {
                record(check, passed: false, detail: "not recorded: the test finished without this check")
            }
        }

        let testChecks = checks[checksBefore...]
        let passed = testChecks.filter(\.passed).count
        let failed = passed < testChecks.count
        // One screenshot at most: a failing last test's fail.png is a copy of its final.png.
        let folder = runDirectory.appendingPathComponent(test.name, isDirectory: true)
        let finalURL = runDirectory.appendingPathComponent("final.png")
        if isLast { await writeScreenshot(of: app, to: finalURL) }
        if failed {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let failURL = folder.appendingPathComponent("fail.png")
            if isLast {
                // copyItem refuses to replace a file, which would leave an older fail.png in place.
                try? FileManager.default.removeItem(at: failURL)
                try? FileManager.default.copyItem(at: finalURL, to: failURL)
            } else {
                await writeScreenshot(of: app, to: failURL)
            }
        }

        // The quit test keeps its window, so quitting is timed with it open.
        if !test.quitsApp { chromiumLog.mark("closing windows of \(test.name)") }
        let leftover =
            test.quitsApp ? nil : await app.closeTestWindows(timeout: Self.cleanupTimeout, baseline: baseline)
        let seconds = Date().timeIntervalSince(started)
        if failed || leftover != nil {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var log = run.log
            for check in testChecks where !check.passed { log.append("failed check: \(check.name)") }
            if let leftover { log.append("left over: \(leftover)") }
            log.append("seconds: \(String(format: "%.2f", seconds))")
            try? (log.joined(separator: "\n") + "\n").write(
                to: folder.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
        }
        let isTimeout = (failure?.error as? E2EError)?.reason == .timeout
        let status = isTimeout ? "timeout" : (failed || leftover != nil ? "fail" : "pass")
        // The quit check is reported after the engine stops, so the quit test's RESULT line says it is pending.
        let pendingQuit = quitCheck != nil && test.quitsApp ? " quit=pending" : ""
        let error = failure.map { " error=\"\($0.step): \($0.error)\"" } ?? ""
        let resultLine =
            "RESULT \(test.name) \(status) seconds=\(String(format: "%.2f", seconds)) "
            + "checks=\(passed)/\(testChecks.count)\(pendingQuit)\(error)"
        chromiumLog.mark(resultLine)
        output.line(resultLine)
        return leftover
    }

    /// Called after the engine has shut down: reports the quit check and the summary, then cleans up.
    func engineDidStop() {
        watchdog.disarm()
        E2ELoopback.stop()
        if let quitCheck {
            // Two times: the app closing every page and ending its message loop, which a person waits for, and
            // the quit up to the end of Chromium's own shutdown, which grows with machine load (spec/quit.md).
            let closed = BowQuitTiming.closeDuration()
            let stopped = BowEngine.quitDuration
            let times =
                "closed=\(Self.preciseSeconds(closed)) limit \(Self.format(quitCheck.closeLimit)), "
                + "stopped=\(Self.preciseSeconds(stopped)) limit \(Self.format(quitCheck.stopLimit))"
            if let quitFailure {
                record(quitCheck.name, passed: false, detail: stopped > 0 ? "\(quitFailure) (\(times))" : quitFailure)
            } else if stopped <= 0 {
                record(quitCheck.name, passed: false, detail: "the quit clock never started, so quitting was not timed")
            } else if closed <= 0 {
                record(
                    quitCheck.name, passed: false,
                    detail: "the closing time was not recorded: main did not call BowEngineMessageLoopDidEnd, "
                        + "or the quit clock started after the message loop ended")
            } else if closed >= quitCheck.closeLimit {
                record(quitCheck.name, passed: false, detail: "closing took too long: \(times)")
            } else if stopped >= quitCheck.stopLimit {
                record(quitCheck.name, passed: false, detail: "Chromium's shutdown took too long: \(times)")
            } else {
                record(quitCheck.name, passed: true, detail: times)
            }
        }

        // A run passes only when its tests recorded checks; chromium.errors alone does not count.
        let testChecks = testCheckCount + (quitCheck == nil ? 0 : 1)
        let log = chromiumLog.finish()
        if log.unexpected.isEmpty {
            record(
                Self.chromiumErrorsCheck, passed: true,
                detail: "unexpected=0 known=\(log.known) temporary=\(log.temporary)")
        } else {
            let count = log.unexpected.count
            let detail =
                "\(count) unexpected ERROR or FATAL lines in \(E2EChromiumLog.fileName) (context in "
                + "\(E2EChromiumErrorContext.fileName)), first: \(log.unexpected[0])"
            record(Self.chromiumErrorsCheck, passed: false, detail: detail)
        }

        let passed = checks.filter(\.passed).count
        let allPassed = testChecks > 0 && passed == checks.count
        output.line("E2E: \(allPassed ? "PASS" : "FAIL") \(passed)/\(checks.count)")
        BowEngine.exitCode = allPassed ? 0 : Self.failureExitCode

        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        // Keep the profile of a failed run for debugging.
        if allPassed { try? FileManager.default.removeItem(at: profileDirectory) }
    }

    /// Writes a screenshot of the running test's page to `url` and prints where it went. A screenshot is evidence,
    /// not a check, so failing to take one is reported without failing the run.
    private func writeScreenshot(of app: E2EAppAdapter, to url: URL) async {
        guard let page = app.evidencePage else {
            output.line("screenshot: not written: the test has no window showing a page")
            return
        }
        let result = await E2ERace.run(
            timeout: Self.screenshotTimeout,
            timeoutError: E2EError("no screenshot after \(Int(Self.screenshotTimeout)) seconds")
        ) {
            try await E2EScreenshot.png(page)
        }
        switch result {
        case .success(let png):
            do {
                try png.write(to: url)
                output.line("screenshot: \(url.path)")
            } catch {
                output.line("screenshot: not written: \(error.localizedDescription)")
            }
        case .failure(let error):
            output.line("screenshot: not written: \(error)")
        }
    }

    fileprivate func record(_ name: String, passed: Bool, detail: String) {
        checks.append((name, passed))
        output.line("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
    }

    fileprivate func expectQuit(
        _ name: String, closingWithin closeLimit: TimeInterval, stoppingWithin stopLimit: TimeInterval
    ) {
        quitCheck = (name, closeLimit, stopLimit)
    }

    /// Fails the check `name` that the running test recorded (at or after index `start` of `checks`), printing a
    /// FAIL line that overrides its earlier PASS without adding to the total. Does nothing when it already failed.
    fileprivate func fail(_ name: String, after start: Int, detail: String) {
        guard let index = checks.indices.last(where: { $0 >= start && checks[$0].name == name }),
            checks[index].passed
        else { return }
        checks[index].passed = false
        output.line("FAIL \(name): \(detail)")
    }

    /// Where the running test's checks start in `checks`.
    fileprivate var checkCount: Int { checks.count }

    /// Re-arms the watchdog from the main thread a few times a second, so it fires only when the main thread has
    /// not answered for `mainThreadStuckTimeout`.
    private func startHeartbeat() {
        let timer = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        beat()
    }

    /// Re-arms the watchdog naming the running test and step. Also called as each test and step starts, so a step
    /// that blocks the main thread at once is still named.
    fileprivate func beat() {
        guard heartbeat != nil else { return }
        let place = activeRun.map { "\($0.testName): \($0.currentStep)" } ?? "between tests"
        watchdog.arm(
            "\(place) (the main thread did not answer for \(Int(Self.mainThreadStuckTimeout)) s)",
            timeout: Self.mainThreadStuckTimeout)
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
        watchdog.disarm()
    }

    /// Prints one line per test: `TEST <name> area=<area> tags=<tags or -> checks=<checks>`.
    private static func list() {
        for test in E2ETests.all {
            let tags = test.tags.isEmpty ? "-" : test.tags.joined(separator: ",")
            print("TEST \(test.name) area=\(test.area) tags=\(tags) checks=\(test.checks.joined(separator: ","))")
        }
        fflush(stdout)
    }

    /// The tests with the one that checks quitting moved to the end, so quitting is timed with only its window.
    private static func quitTestLast(_ tests: [any E2ETest]) -> [any E2ETest] {
        tests.filter { !$0.quitsApp } + tests.filter(\.quitsApp)
    }

    private static let defaultsSuitePrefix = "dev.bowbrowser.Bow.e2e."

    /// Removes settings suites left by runs that ended without cleaning up (a timeout or a crash).
    private static func removeStaleDefaultsSuites() {
        let fileManager = FileManager.default
        let preferences = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
        let files = (try? fileManager.contentsOfDirectory(atPath: preferences.path)) ?? []
        for file in files where file.hasPrefix(defaultsSuitePrefix) && file.hasSuffix(".plist") {
            let suite = String(file.dropLast(".plist".count))
            // Leave suites of runs still going (named after their process ID).
            guard let pid = Int32(suite.dropFirst(defaultsSuitePrefix.count)), kill(pid, 0) != 0 else { continue }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? fileManager.removeItem(at: preferences.appendingPathComponent(file))
        }
    }

    /// Seconds with three decimals, so a close of a few milliseconds does not read as zero.
    private static func preciseSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.2f", seconds)
    }
}

/// What a test uses while it runs: the app, timed steps and checks.
@MainActor
final class E2ERun {
    let app: any E2EApp
    /// The step running now, or `after <step>` once it has finished, for FAIL lines. A step that throws or times
    /// out keeps its own name.
    private(set) var currentStep = "before the first step"
    /// The run's throwaway Chromium root, where persistent profiles keep their folders.
    var dataDirectory: URL { runner.profileDirectory }
    var testName: String { test.name }

    /// When the running step's limit runs out; nil between steps. Waits give up shortly before it.
    static var stepDeadline: Date?

    /// The checks recorded so far, the quit check included once expected.
    fileprivate private(set) var recorded = Set<String>()
    /// One line per step: its name, limit, duration and outcome, for the failing test's log.txt.
    fileprivate private(set) var log: [String] = []
    /// The run's throwaway downloads folder, where the app saves downloads during the run.
    var downloadsDirectory: URL { runner.downloadsDirectory }

    private unowned let runner: E2ERunner
    private let test: any E2ETest
    private let deadline = Date(timeIntervalSinceNow: E2ERun.testTimeout)
    private var finished = false
    /// Where this test's checks start in the runner's list.
    fileprivate let firstCheck: Int
    /// Checks recorded more than once, each failed once already.
    private var repeated = Set<String>()

    fileprivate init(runner: E2ERunner, test: any E2ETest, app: any E2EApp) {
        self.runner = runner
        self.test = test
        self.app = app
        firstCheck = runner.checkCount
    }

    /// Runs one step. If it has not finished after `timeout` seconds (or the test's own limit runs out first), the
    /// step throws a TIMEOUT error, which fails the test, and the run goes on with the next test (the step's work
    /// is cancelled and its windows closed).
    func step<T>(_ name: String, timeout: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T {
        // A test that ran past its limit can still be running here; it must not drive the app any further.
        guard !finished else { throw E2EError("the test had already ended when it started \(name)") }
        currentStep = name
        runner.beat()
        let limitedByTest = remainingTime < timeout
        let limit = min(timeout, remainingTime)
        let started = Date()
        let outerDeadline = Self.stepDeadline
        Self.stepDeadline = started.addingTimeInterval(limit)
        defer { Self.stepDeadline = outerDeadline }
        let which = limitedByTest ? "the test's \(Int(Self.testTimeout)) s limit" : "its \(Self.format(limit)) s limit"
        let result = await E2ERace.run(
            timeout: limit, timeoutError: E2EError("TIMEOUT: the step ran past \(which)", reason: .timeout), body)
        let seconds = Self.format(Date().timeIntervalSince(started))
        switch result {
        case .success(let value):
            log.append("step \(name): ok in \(seconds) s (limit \(Self.format(limit)) s)")
            currentStep = "after \(name)"
            return value
        case .failure(let error):
            log.append("step \(name): failed in \(seconds) s (limit \(Self.format(limit)) s): \(error)")
            throw error
        }
    }

    /// The whole test, steps and code between them, must finish within this many seconds.
    static let testTimeout: TimeInterval = 120
    private var remainingTime: TimeInterval { max(deadline.timeIntervalSinceNow, 0.001) }

    /// Records a check, printing `PASS name: detail` or `FAIL <step>: name: detail`. A check the test does not
    /// declare in `E2ETest.checks` fails, so the run's total stays the same however far tests get. A check recorded
    /// a second time (in a loop, say) fails once, keeping its single place in the total.
    func check(_ name: String, passed: Bool, _ detail: String) {
        guard !finished else {
            log.append("ignored late check \(name) from a step that had timed out: \(detail)")
            return
        }
        // FAIL lines name the step, as a failing step's error does.
        let failDetail = "\(currentStep): \(detail)"
        guard recorded.insert(name).inserted else {
            log.append("check \(name) recorded again in \(currentStep): \(detail)")
            guard repeated.insert(name).inserted else { return }
            runner.fail(
                name, after: firstCheck,
                detail: "\(failDetail) (recorded more than once; record each check once per test)")
            return
        }
        if !test.checks.contains(name) {
            runner.record(name, passed: false, detail: "\(failDetail) (not declared in the checks of \(test.name))")
        } else {
            runner.record(name, passed: passed, detail: passed ? detail : failDetail)
        }
    }

    /// Checks, after the engine has shut down, that every page closed and the message loop ended in less than
    /// `closeLimit` seconds, and that the quit up to the end of Chromium's shutdown took less than `stopLimit`.
    /// Only the test whose `quitsApp` is true may call it; it runs last and keeps its windows, so quitting is timed
    /// with them alone.
    func expectQuit(_ name: String, closingWithin closeLimit: TimeInterval, stoppingWithin stopLimit: TimeInterval) {
        guard !finished else { return }
        guard test.quitsApp else {
            check(name, passed: false, "expectQuit needs quitsApp in \(test.name)")
            return
        }
        guard stopLimit < E2ERunner.quitHangTimeout else {
            // A quit slower than the hang watchdog ends the run before this check could report it.
            let limit = E2ERunner.quitHangTimeout
            check(name, passed: false, "stoppingWithin must be below the quit hang limit (\(limit) s)")
            return
        }
        recorded.insert(name)
        runner.expectQuit(name, closingWithin: closeLimit, stoppingWithin: stopLimit)
    }

    /// Ends the test: checks from steps still running after a timeout are ignored from now on.
    fileprivate func finish() {
        finished = true
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }
}

/// Runs work on the main actor against a time limit. Whichever finishes first, the work or the limit, decides the
/// result; work that loses is cancelled and its late result dropped.
@MainActor
enum E2ERace {
    static func run<T>(
        timeout: TimeInterval,
        timeoutError: Error,
        _ body: @escaping () async throws -> T
    ) async -> Result<T, Error> {
        let race = Race<T>()
        // Everything here runs on the main actor; the box only carries the closure and its result across the
        // Task and continuation boundaries the compiler cannot see through.
        let work = Unchecked(body)
        let boxed: Unchecked<Result<T, Error>> = await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.task = Task { @MainActor in
                do {
                    race.finish(.success(try await work.value()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let failure = Unchecked(timeoutError)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { race.finish(.failure(failure.value)) }
            }
        }
        return boxed.value
    }

    @MainActor
    private final class Race<T> {
        var continuation: CheckedContinuation<Unchecked<Result<T, Error>>, Never>?
        var task: Task<Void, Never>?

        func finish(_ result: Result<T, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            if case .failure(let error as E2EError) = result, error.reason == .timeout { task?.cancel() }
            continuation.resume(returning: Unchecked(result))
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
}
