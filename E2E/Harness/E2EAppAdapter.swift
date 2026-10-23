import AppKit

// The only e2e file that knows the bridge (BowEngine, BowTab, BowWebView, BowDevToolsSession) and the window
// controllers. When the bridge changes shape, rewrite this file to keep E2EApp and E2EPage working; tests stay as
// they are.

@MainActor
final class E2EAppAdapter: E2EApp {
    /// Far from every screen. The window subclass keeps AppKit from moving it back on screen.
    static let windowFrame = NSRect(x: -20_000, y: -20_000, width: 1280, height: 800)

    private(set) var lastOpenedPage: (any E2EPage)?
    private unowned let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    func openWindow(at url: URL, newProfile profile: E2EProfile?) async throws -> any E2EPage {
        let bowProfile: BowProfile
        if let profile {
            bowProfile = try BowEngine.shared.createProfile(id: profile.id, persistent: profile.isPersistent)
        } else {
            bowProfile = BowEngine.shared.defaultProfile
        }
        let window = OffscreenBrowserWindow(
            contentRect: Self.windowFrame,
            styleMask: BrowserWindowController.styleMask,
            backing: .buffered,
            defer: false
        )
        let controller = delegate.openWindow(url: url, profile: bowProfile, window: window)
        guard let window = controller.window else { throw E2EError("the window controller has no window") }
        guard let tab = controller.selectedTab else { throw E2EError("the window opened without a tab") }
        // Made before the checks below wait, so the page hears every load event.
        let page = TabPage(tab: tab, controller: controller)
        // Creating a titled window moves it onto a screen; put it back where it belongs.
        window.setFrame(window.frameRect(forContentRect: Self.windowFrame), display: false)
        // Check before ordering the window in, so a broken setup fails instead of showing a window.
        try await Self.checkInvisible(window)
        // Ordered in without activating the app or becoming key, so it composites like a visible window.
        window.orderFrontRegardless()
        try await Self.checkInvisible(window)
        lastOpenedPage = page
        return page
    }

    func openTab(at url: URL, besides page: any E2EPage, select: Bool) throws -> any E2EPage {
        let controller = try Self.tabPage(page).controller
        let tab = controller.openTab(url: url, select: select)
        return TabPage(tab: tab, controller: controller)
    }

    func select(_ page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        page.controller.select(page.tab)
        guard page.isShown else { throw E2EError("tab \(page.tab.tabID) is not shown after selecting it") }
    }

    func closeWindow(of page: any E2EPage) async throws {
        let controller = try Self.tabPage(page).controller
        guard let window = controller.window else { throw E2EError("the page has no window") }
        window.performClose(nil)
        // The window closes once its last tab has; the caller's step timeout bounds the wait.
        while window.isVisible {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func tabPage(_ page: any E2EPage) throws -> TabPage {
        guard let page = page as? TabPage else { throw E2EError("the page did not come from this app") }
        return page
    }

    private static func checkInvisible(_ window: NSWindow) async throws {
        try await checkAccessory()
        if window.canBecomeKey || window.canBecomeMain || window.isKeyWindow {
            throw E2EError("the window can take keyboard focus")
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) {
            throw E2EError("the window at \(window.frame) would show on screen \(screen.frame)")
        }
    }

    /// How long the activation policy may read as something other than accessory before the check fails.
    static let policySettleTimeout: TimeInterval = 2

    /// Throws unless the app is an accessory app, waiting out a brief wrong reading first.
    ///
    /// The bundle declares a regular app (Chromium reads LSUIElement to tell its helper processes from the browser,
    /// so the app cannot set it), and the runner switches to accessory at launch. In about a third of runs, macOS
    /// then reports the declared type again for a few milliseconds, some 30 ms after the first window is ordered in,
    /// with no policy change from the app; a check landing in that moment failed the run. A policy that stays wrong
    /// still fails.
    private static func checkAccessory() async throws {
        let deadline = Date().addingTimeInterval(policySettleTimeout)
        while NSApp.activationPolicy() != .accessory {
            guard Date() < deadline else {
                throw E2EError("the app is not an accessory app, so it could show in the Dock and take focus")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func quit() {
        // Tests no longer hold their pages; releasing the last one here frees its DevTools session (and the
        // Chromium objects it holds) while the engine still runs.
        lastOpenedPage = nil
        NSApp.terminate(nil)
    }
}

/// E2EPage over one tab and a DevTools session on its browser.
@MainActor
private final class TabPage: E2EPage {
    let tab: BowTab
    let controller: BrowserWindowController
    private let devToolsSession: BowDevToolsSession
    /// Every finished main frame load, in order; load number n is `loads[n - 1]`.
    private var loads: [Result<Int, E2EError>] = []
    private var loadWaiters: [(load: Int, continuation: CheckedContinuation<Int, Error>)] = []
    /// The URL of the last failed load. Chromium then shows an error page at that URL and reports its load end
    /// too, which belongs to the same failed load and must not count as another one.
    private var failedURL: String?

    init(tab: BowTab, controller: BrowserWindowController) {
        self.tab = tab
        self.controller = controller
        devToolsSession = BowDevToolsSession(tabID: tab.tabID)
        tab.onLoadEnd = { [weak self, unowned tab] status in
            guard let self else { return }
            let isErrorPage = failedURL != nil && failedURL == tab.state.url?.absoluteString
            failedURL = nil
            if !isErrorPage { loadFinished(.success(status)) }
        }
        tab.onLoadError = { [weak self] code, text, url in
            self?.failedURL = url
            self?.loadFinished(.failure(E2EError("loading \(url) failed: \(code) \(text)")))
        }
        // Let go of a tab that closes during the run. At quit this comes too late (it runs after the engine may
        // have shut down), so quit() also drops the last page, and with it the session, before quitting.
        let onClose = tab.onClose
        tab.onClose = { [weak devToolsSession] in
            devToolsSession?.close()
            onClose?()
        }
    }

    var isShown: Bool { controller.webView.attachedTab === tab }
    /// The window's web view while it shows this tab; nil while another tab is shown or once the window is gone.
    var contentView: NSView? { isShown && controller.window != nil ? controller.webView : nil }
    var isClosed: Bool { tab.isClosed }
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
