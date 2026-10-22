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
    private var finishedLoad: Result<Int, E2EError>?
    private var loadWaiters: [CheckedContinuation<Int, Error>] = []

    init(webView: BowWebView) {
        devToolsSession = BowDevToolsSession(hostView: webView)
        webView.onLoadEnd = { [weak self] status in
            self?.loadFinished(.success(status))
        }
        webView.onLoadError = { [weak self] code, text, url in
            self?.loadFinished(.failure(E2EError("loading \(url) failed: \(code) \(text)")))
        }
    }

    func waitForLoad() async throws -> Int {
        if let finishedLoad {
            self.finishedLoad = nil
            return try finishedLoad.get()
        }
        return try await withCheckedThrowingContinuation { loadWaiters.append($0) }
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
        guard !loadWaiters.isEmpty else {
            finishedLoad = result
            return
        }
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters { waiter.resume(with: result.mapError { $0 as Error }) }
    }
}

/// A DevTools result handed from the session's completion to the awaiting page. Both run on the main thread
/// and the dictionary is never touched elsewhere, so passing it along is safe.
private struct MainThreadResult: @unchecked Sendable {
    let value: [String: Any]
}
