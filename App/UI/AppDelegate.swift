import AppKit
import BowCore

@objc(AppDelegate)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let homeURL = URL(string: "https://www.google.com")!
    /// Chromium's profiles and caches for normal and smoke runs.
    private static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bow", isDirectory: true)
    }
    private static let smokeTestTimeout: TimeInterval = 30
    /// A smoke run fails with `BowEngineQuitTimeoutExitCode` if quitting takes longer than this.
    private static let smokeQuitTimeout: TimeInterval = 2
    /// Exit code for switches the app cannot parse (EX_USAGE).
    private static let usageExitCode: Int32 = 64

    /// The engine as app code sees it: the BowCore protocols over the bridge.
    let engine: any BrowserEngine = CEFEngine()
    private var windowControllers: [BrowserWindowController] = []
    private var options = LaunchOptions()
    #if BOW_E2E
        private var e2eRunner: E2ERunner?  // E2E seam
    #endif
    private var smokeTimer: Timer?
    private var smokeFinished = false
    /// The smoke run's window, for the navigation delegate methods that finish the run.
    private weak var smokeController: BrowserWindowController?

    /// Called by main before Chromium starts: reads the launch switches and says how to start the engine.
    /// Returns nil, with `BowEngine.exitCode` set, when the switches are unusable and the app should exit.
    @objc func engineConfiguration() -> BowEngineConfiguration? {
        do {
            options = try LaunchOptions.parse(ProcessInfo.processInfo.arguments)
            if options.isE2E {
                #if BOW_E2E
                    let runner = try E2ERunner(options: options)  // E2E seam: the runner sets up the run.
                    e2eRunner = runner
                    return runner.engineConfiguration
                #else
                    FileHandle.standardError.write(
                        Data("bow: --e2e needs a Debug build; this one has no e2e harness\n".utf8))
                    BowEngine.exitCode = Self.usageExitCode
                    return nil
                #endif
            }
        } catch {
            FileHandle.standardError.write(Data("bow: \(error)\n".utf8))
            BowEngine.exitCode = Self.usageExitCode
            return nil
        }

        let configuration = BowEngineConfiguration(rootDataDirectory: Self.dataDirectory.path)
        if options.isSmokeTest {
            configuration.quitTimeout = Self.smokeQuitTimeout
            configuration.reportsQuitTime = true
        }
        return configuration
    }

    /// Called by the engine once Chromium is ready to create browsers.
    @objc func engineDidStart() {
        NSApp.mainMenu = MainMenu.make()
        #if BOW_E2E
            if let e2eRunner {  // E2E seam: an e2e run hands control to its runner.
                e2eRunner.start(delegate: self)
                return
            }
        #endif

        let startURL = options.smokeInput.flatMap(AddressInput.resolve) ?? Self.homeURL
        let controller = openWindow(url: startURL)
        if options.isSmokeTest {
            // Stay in the background so a smoke run never takes the keyboard from whoever is typing.
            controller.window?.orderBack(nil)
            runSmokeTest(in: controller)
        } else {
            controller.showWindow(nil)
            NSApp.activate()
        }
    }

    /// Called by main after the engine has shut down, just before the process exits with `BowEngine.exitCode`.
    @objc func engineDidStop() {
        #if BOW_E2E
            e2eRunner?.engineDidStop()  // E2E seam
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // An e2e run quits when its tests are done, even if a test closes every window on the way.
        !options.isE2E
    }

    /// Opens `url` in a new browser window on `profile` (the default profile when nil), or in `window` when given
    /// (e2e runs pass an off-screen one).
    func openWindow(
        url: URL,
        profile: (any EngineProfile)? = nil,
        window: BrowserWindow? = nil
    ) -> BrowserWindowController {
        // The engine always has its default profile.
        let profile = profile ?? engine.profile(id: .default)!
        let controller = BrowserWindowController(url: url, profile: profile, window: window)
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        return controller
    }

    /// Loads the start page, prints one result line, and quits the way `--smoke-quit` says,
    /// with exit code 0 when the page loaded.
    private func runSmokeTest(in controller: BrowserWindowController) {
        smokeController = controller
        guard let tab = controller.selectedTab else {
            finishSmokeTest("no tab opened", exitCode: 1)
            return
        }
        // The first main frame load that finishes or fails ends the run.
        let tabID = tab.tabID
        controller.onTabEvent = { [weak self] eventTab, event in
            guard eventTab.tabID == tabID else { return }
            self?.smokeTab(eventTab, didReceive: event)
        }
        smokeTimer = Timer.scheduledTimer(withTimeInterval: Self.smokeTestTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishSmokeTest("timed out", exitCode: 2)
            }
        }
    }

    /// Runs once: later loads, errors or the timeout cannot print a second line or change the exit code.
    private func finishSmokeTest(_ line: String, exitCode: Int32) {
        guard !smokeFinished else { return }
        smokeFinished = true
        smokeTimer?.invalidate()
        smokeTimer = nil

        FileHandle.standardOutput.write(Data("smoke: \(line)\n".utf8))
        BowEngine.exitCode = exitCode
        // Time every quit method from here, including closing the window before the app quits.
        BowEngine.startQuitClock()
        // Quit from a fresh main thread task rather than inside the engine's load callback.
        let quitMethod = options.smokeQuit
        DispatchQueue.main.async { [weak window = smokeController?.window] in
            Self.quit(by: quitMethod, window: window)
        }
    }

    /// Quits the way a person would, so each path is checked end to end.
    private static func quit(by method: LaunchOptions.QuitMethod, window: NSWindow?) {
        switch method {
        case .terminate:
            NSApp.terminate(nil)
        case .menu:
            let commandQ = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "q",
                charactersIgnoringModifiers: "q",
                isARepeat: false,
                keyCode: 12
            )
            if let commandQ, NSApp.mainMenu?.performKeyEquivalent(with: commandQ) == true { return }
            FileHandle.standardError.write(Data("smoke: Cmd+Q matched no menu item\n".utf8))
            BowEngine.exitCode = 1
            NSApp.terminate(nil)
        case .closeWindow:
            guard let window else {
                FileHandle.standardError.write(Data("smoke: no window to close\n".utf8))
                BowEngine.exitCode = 1
                NSApp.terminate(nil)
                return
            }
            window.performClose(nil)
        }
    }
}

/// A smoke run's result: the first load of its tab that finishes or fails.
extension AppDelegate {
    fileprivate func smokeTab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .didFinish(let navigation, let httpStatus):
            let ok = (200..<400).contains(httpStatus)
            let url = tab.state.url?.absoluteString ?? navigation.url.absoluteString
            let line = "status=\(httpStatus) title=\"\(tab.state.title)\" url=\(url)"
            finishSmokeTest(line, exitCode: ok ? 0 : 1)
        case .didFail(let navigation, let error):
            // An aborted load was replaced (a script navigation or a meta refresh) or left no page; the result is
            // the load that follows, or the timeout.
            if error.isAborted { return }
            let line = "error=\(error.code) \(error.description) url=\(navigation.url.absoluteString)"
            finishSmokeTest(line, exitCode: 1)
        default:
            break
        }
    }
}
