import AppKit
import BowCore

@objc(AppDelegate)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let homeURL = URL(string: "https://www.google.com")!
    private static let smokeTestTimeout: TimeInterval = 30
    /// A smoke run fails with `BowEngineQuitTimeoutExitCode` if quitting takes longer than this.
    private static let smokeQuitTimeout: TimeInterval = 2
    /// Exit code for switches the app cannot parse (EX_USAGE).
    private static let usageExitCode: Int32 = 64

    private var windowControllers: [BrowserWindowController] = []
    private var smokeTimer: Timer?
    private var smokeFinished = false

    /// Called by the engine once Chromium is ready to create browsers.
    @objc func engineDidStart() {
        NSApp.mainMenu = MainMenu.make()

        let options: LaunchOptions
        do {
            options = try LaunchOptions.parse(ProcessInfo.processInfo.arguments)
        } catch {
            FileHandle.standardError.write(Data("bow: \(error)\n".utf8))
            BowEngine.exitCode = Self.usageExitCode
            // Wait for the message loop to be running, so ending it takes effect.
            DispatchQueue.main.async { BowEngine.quit() }
            return
        }

        let startURL = options.smokeInput.flatMap(AddressInput.resolve) ?? Self.homeURL
        let controller = openWindow(url: startURL)
        if options.isSmokeTest {
            BowEngine.quitTimeout = Self.smokeQuitTimeout
            BowEngine.reportsQuitTime = true
            // Stay in the background so a smoke run never takes the keyboard from whoever is typing.
            controller.window?.orderBack(nil)
            runSmokeTest(in: controller, quitting: options.smokeQuit)
        } else {
            controller.showWindow(nil)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func openWindow(url: URL) -> BrowserWindowController {
        let controller = BrowserWindowController(url: url)
        controller.onClose = { [weak self] closed in
            self?.windowControllers.removeAll { $0 === closed }
        }
        windowControllers.append(controller)
        return controller
    }

    /// Loads the start page, prints one result line, and quits the way `quitMethod` says,
    /// with exit code 0 when the page loaded.
    private func runSmokeTest(in controller: BrowserWindowController, quitting quitMethod: LaunchOptions.QuitMethod) {
        let webView = controller.webView
        webView.onLoadEnd = { [weak self, unowned webView, weak controller] status in
            let ok = (200..<400).contains(status)
            let line = "status=\(status) title=\"\(webView.title)\" url=\(webView.currentURL)"
            self?.finishSmokeTest(line, exitCode: ok ? 0 : 1, window: controller?.window, quitMethod: quitMethod)
        }
        webView.onLoadError = { [weak self, weak controller] code, text, url in
            let line = "error=\(code) \(text) url=\(url)"
            self?.finishSmokeTest(line, exitCode: 1, window: controller?.window, quitMethod: quitMethod)
        }
        smokeTimer = Timer.scheduledTimer(withTimeInterval: Self.smokeTestTimeout, repeats: false) {
            [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                self?.finishSmokeTest("timed out", exitCode: 2, window: controller?.window, quitMethod: quitMethod)
            }
        }
    }

    /// Runs once: later loads, errors or the timeout cannot print a second line or change the exit code.
    private func finishSmokeTest(
        _ line: String,
        exitCode: Int32,
        window: NSWindow?,
        quitMethod: LaunchOptions.QuitMethod
    ) {
        guard !smokeFinished else { return }
        smokeFinished = true
        smokeTimer?.invalidate()
        smokeTimer = nil

        FileHandle.standardOutput.write(Data("smoke: \(line)\n".utf8))
        BowEngine.exitCode = exitCode
        // Time every quit method from here, including closing the window before the app quits.
        BowEngine.startQuitClock()
        // Quit from a fresh main thread task rather than inside the engine's load callback.
        DispatchQueue.main.async { [weak window] in
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
