import AppKit
import BowCore

@objc(AppDelegate)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let homeURL = URL(string: "https://www.google.com")!
    private static let smokeTestTimeout: TimeInterval = 30

    private var windowControllers: [BrowserWindowController] = []

    /// Called by the engine once Chromium is ready to create browsers.
    @objc func engineDidStart() {
        NSApp.mainMenu = MainMenu.make()

        let smokeInput = Self.argumentValue("--smoke-test")
        let startURL = smokeInput.flatMap(AddressInput.resolve) ?? Self.homeURL
        let controller = BrowserWindowController(url: startURL)
        windowControllers.append(controller)
        if smokeInput != nil {
            // Stay in the background so a smoke run never takes the keyboard from whoever is typing.
            controller.window?.orderBack(nil)
            runSmokeTest(on: controller.webView)
        } else {
            controller.showWindow(nil)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Loads the start page, prints the result, and quits with exit code 0 on success.
    private func runSmokeTest(on webView: BowWebView) {
        webView.onLoadEnd = { [unowned self, unowned webView] status in
            let ok = (200..<400).contains(status)
            let summary = "status=\(status) title=\"\(webView.title)\" url=\(webView.currentURL)"
            finishSmokeTest(summary, exitCode: ok ? 0 : 1)
        }
        webView.onLoadError = { [unowned self] code, text, url in
            finishSmokeTest("error=\(code) \(text) url=\(url)", exitCode: 1)
        }
        Timer.scheduledTimer(withTimeInterval: Self.smokeTestTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishSmokeTest("timed out", exitCode: 2) }
        }
    }

    private func finishSmokeTest(_ line: String, exitCode: Int32) {
        FileHandle.standardOutput.write(Data("smoke: \(line)\n".utf8))
        BowEngine.exitCode = exitCode
        NSApp.terminate(nil)
    }

    private static func argumentValue(_ name: String) -> String? {
        let prefix = name + "="
        let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
        return argument.map { String($0.dropFirst(prefix.count)) }
    }
}
