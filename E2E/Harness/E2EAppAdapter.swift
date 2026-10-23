import AppKit

// The only e2e file that knows the bridge (BowWebView, BowDevToolsSession) and the window controllers.
// When the bridge changes shape, rewrite this file to keep E2EApp and E2EPage working; tests stay as they are.

@MainActor
final class E2EAppAdapter: E2EApp {
    /// Far from every screen. The window subclass keeps AppKit from moving it back on screen.
    static let windowFrame = NSRect(x: -20_000, y: -20_000, width: 1280, height: 800)

    private unowned let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    func openWindow(at url: URL) throws -> any E2EPage {
        let window = OffscreenBrowserWindow(
            contentRect: Self.windowFrame,
            styleMask: BrowserWindowController.styleMask,
            backing: .buffered,
            defer: false
        )
        let controller = delegate.openWindow(url: url, window: window)
        guard let window = controller.window else { throw E2EError("the window controller has no window") }
        // Creating a titled window moves it onto a screen; put it back where it belongs.
        window.setFrame(window.frameRect(forContentRect: Self.windowFrame), display: false)
        // Check before ordering the window in, so a broken setup fails instead of showing a window.
        try Self.checkInvisible(window)
        // Ordered in without activating the app or becoming key, so it composites like a visible window.
        window.orderFrontRegardless()
        try Self.checkInvisible(window)
        return WebViewPage(webView: controller.webView)
    }

    private static func checkInvisible(_ window: NSWindow) throws {
        if NSApp.activationPolicy() != .accessory {
            throw E2EError("the app is not an accessory app, so it could show in the Dock and take focus")
        }
        if window.canBecomeKey || window.canBecomeMain || window.isKeyWindow {
            throw E2EError("the window can take keyboard focus")
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) {
            throw E2EError("the window at \(window.frame) would show on screen \(screen.frame)")
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }
}

/// E2EPage over a BowWebView and a DevTools session on its browser.
@MainActor
private final class WebViewPage: E2EPage {
    private let devToolsSession: BowDevToolsSession
    /// Every finished main frame load, in order; load number n is `loads[n - 1]`.
    private var loads: [Result<Int, E2EError>] = []
    private var loadWaiters: [(load: Int, continuation: CheckedContinuation<Int, Error>)] = []
    /// The URL of the last failed load. Chromium then shows an error page at that URL and reports its load end
    /// too, which belongs to the same failed load and must not count as another one.
    private var failedURL: String?

    init(webView: BowWebView) {
        devToolsSession = BowDevToolsSession(hostView: webView)
        webView.onLoadEnd = { [weak self, unowned webView] status in
            guard let self else { return }
            let isErrorPage = failedURL == webView.currentURL
            failedURL = nil
            if !isErrorPage { loadFinished(.success(status)) }
        }
        webView.onLoadError = { [weak self] code, text, url in
            self?.failedURL = url
            self?.loadFinished(.failure(E2EError("loading \(url) failed: \(code) \(text)")))
        }
    }

    var finishedLoads: Int { loads.count }

    func waitForLoad(after finishedLoads: Int) async throws -> Int {
        let load = finishedLoads + 1
        if load <= loads.count { return try loads[load - 1].get() }
        return try await withCheckedThrowingContinuation { loadWaiters.append((load, $0)) }
    }

    func devTools(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let response = try await withCheckedThrowingContinuation { continuation in
            devToolsSession.callMethod(method, params: params) { result, error in
                if let result {
                    continuation.resume(returning: MainThreadResult(value: result))
                } else {
                    let message = error?.localizedDescription ?? "no result"
                    continuation.resume(throwing: E2EError("\(method): \(message)"))
                }
            }
        }
        return response.value
    }

    private func loadFinished(_ result: Result<Int, E2EError>) {
        loads.append(result)
        let ready = loadWaiters.filter { $0.load == loads.count }
        loadWaiters.removeAll { $0.load == loads.count }
        for waiter in ready { waiter.continuation.resume(with: result.mapError { $0 as Error }) }
    }
}

/// A DevTools result handed from the session's completion to the awaiting page. Both run on the main thread
/// and the dictionary is never touched elsewhere, so passing it along is safe.
private struct MainThreadResult: @unchecked Sendable {
    let value: [String: Any]
}
