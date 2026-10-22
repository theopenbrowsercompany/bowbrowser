import AppKit
import BowCore

/// Runs e2e scenarios inside the real app (`Bow --e2e=<scenario or all> --e2e-out=<folder>`).
///
/// The run uses a throwaway Chromium root and UserDefaults suite, an off-screen window that never takes focus,
/// no network and fixture pages at `https://bow.test/`. It prints one `PASS name` or `FAIL name: reason` line
/// per check and a final `E2E: PASS n/n` (or `E2E: FAIL passed/n`) line, to stdout and `<folder>/report.txt`.
/// Exit codes: 0 when every check passed, 1 when one failed, 2 when a step timed out.
@MainActor
final class E2EHarness {
    static let failureExitCode: Int32 = 1
    /// Generous, because parallel builds in other worktrees can starve Chromium's start.
    static let engineStartTimeout: TimeInterval = 60
    /// Quitting is checked against its own limit; this only stops a quit that hangs.
    static let quitHangTimeout: TimeInterval = 15

    let engineConfiguration: BowEngineConfiguration

    private let scenarios: [any E2EScenario]
    private let profileDirectory: URL
    private let fixtureDirectory: URL
    private let defaultsSuiteName: String
    private let output: E2EOutput
    private let watchdog: E2EWatchdog
    private var checks: [(name: String, passed: Bool)] = []
    private var quitCheck: (name: String, limit: TimeInterval)?

    /// Prepares a run before the engine starts. Throws for an unknown scenario or an unusable output folder.
    init(options: LaunchOptions) throws {
        guard let selection = options.e2eScenario, let outputPath = options.e2eOutput else {
            throw E2EError("not an e2e run")
        }
        scenarios = try Self.scenarios(named: selection)

        let fileManager = FileManager.default
        let runDirectory = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        profileDirectory = runDirectory.appendingPathComponent("profile", isDirectory: true)
        do {
            try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: profileDirectory.path) {
                try fileManager.removeItem(at: profileDirectory)
            }
            try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        } catch {
            throw E2EError("cannot prepare \(runDirectory.path): \(error.localizedDescription)")
        }
        guard let fixtures = Bundle.main.resourceURL?.appendingPathComponent("Fixtures", isDirectory: true),
            fileManager.fileExists(atPath: fixtures.path)
        else {
            throw E2EError("the app bundle has no Fixtures folder")
        }

        fixtureDirectory = fixtures
        output = E2EOutput(reportURL: runDirectory.appendingPathComponent("report.txt"))
        watchdog = E2EWatchdog(output: output)
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
            // No updates, first run work or network of any kind; fixtures are served without DNS.
            "disable-component-update": "",
            "disable-background-networking": "",
            "no-first-run": "",
            "host-resolver-rules": "MAP * ~NOTFOUND",
            // The same colors and language on every machine.
            "force-color-profile": "srgb",
            "lang": "en-US",
        ]
        engineConfiguration = configuration

        AppSettings.defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        // Never restore windows from an earlier run, and never show in the Dock or take focus.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["ApplePersistenceIgnoreState"] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        watchdog.arm("engine.start", timeout: Self.engineStartTimeout)
    }

    /// Runs the scenarios once the engine has started, then quits.
    func start(delegate: AppDelegate) {
        watchdog.disarm()
        BowFixtureServer.serveDirectory(fixtureDirectory.path)
        let app = E2EAppAdapter(delegate: delegate)
        Task {
            for scenario in scenarios {
                let run = E2ERun(harness: self, scenario: scenario.name, app: app)
                do {
                    try await scenario.run(run)
                } catch {
                    record(scenario.name, passed: false, detail: "\(run.currentStep): \(error)")
                }
                watchdog.disarm()
            }
            watchdog.arm(quitCheck?.name ?? "app.quit", timeout: Self.quitHangTimeout)
            app.quit()
        }
    }

    /// Called after the engine has shut down: reports the quit check and the summary, then cleans up.
    func engineDidStop() {
        watchdog.disarm()
        if let quitCheck {
            let seconds = BowEngine.quitDuration
            let limit = Self.format(quitCheck.limit)
            if seconds < quitCheck.limit {
                record(quitCheck.name, passed: true, detail: "seconds<\(limit)")
            } else {
                record(quitCheck.name, passed: false, detail: "seconds=\(Self.format(seconds)), limit \(limit)")
            }
        }

        let passed = checks.filter(\.passed).count
        let allPassed = !checks.isEmpty && passed == checks.count
        output.line("E2E: \(allPassed ? "PASS" : "FAIL") \(passed)/\(checks.count)")
        BowEngine.exitCode = allPassed ? 0 : Self.failureExitCode

        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        // Keep the profile of a failed run for debugging.
        if allPassed { try? FileManager.default.removeItem(at: profileDirectory) }
    }

    fileprivate func record(_ name: String, passed: Bool, detail: String) {
        checks.append((name, passed))
        output.line("\(passed ? "PASS" : "FAIL") \(name): \(detail)")
    }

    fileprivate func expectQuit(_ name: String, within limit: TimeInterval) {
        quitCheck = (name, limit)
    }

    fileprivate func arm(_ step: String, timeout: TimeInterval) {
        watchdog.arm(step, timeout: timeout)
    }

    private static func scenarios(named selection: String) throws -> [any E2EScenario] {
        if selection == "all" { return E2EScenarios.all }
        let matching = E2EScenarios.all.filter { $0.name == selection }
        guard !matching.isEmpty else {
            let known = E2EScenarios.all.map(\.name).joined(separator: ", ")
            throw E2EError("--e2e=\(selection) is not a scenario; use all or one of: \(known)")
        }
        return matching
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

    private static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.2f", seconds)
    }
}

/// What a scenario uses while it runs: the app, timed steps and checks.
@MainActor
final class E2ERun {
    let app: any E2EApp
    /// The step running now, for FAIL lines.
    private(set) var currentStep = "start"

    private unowned let harness: E2EHarness
    private let scenario: String

    fileprivate init(harness: E2EHarness, scenario: String, app: any E2EApp) {
        self.harness = harness
        self.scenario = scenario
        self.app = app
    }

    /// Runs one step. If it has not finished after `timeout` seconds, the run ends with `E2E: TIMEOUT`.
    func step<T>(_ name: String, timeout: TimeInterval, _ body: () async throws -> T) async throws -> T {
        currentStep = name
        harness.arm("\(scenario): \(name)", timeout: timeout)
        return try await body()
    }

    /// Records a check, printing `PASS name: detail` or `FAIL name: detail`.
    func check(_ name: String, passed: Bool, _ detail: String) {
        harness.record(name, passed: passed, detail: detail)
    }

    /// Checks, after the engine has shut down, that quitting took less than `limit` seconds.
    /// The app quits once every scenario has run, so this is reported after all other checks.
    func expectQuit(_ name: String, within limit: TimeInterval) {
        harness.expectQuit(name, within: limit)
    }
}
