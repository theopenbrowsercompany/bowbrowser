import AppKit
import BowCore

// The only e2e file that knows the app's engine (the BowCore protocols the app drives it through), the window
// controllers and the bridge's BowDevToolsSession and BowLeavePrompts. When those change shape, rewrite this file
// to keep E2EApp and E2EPage working; tests stay as they are.

@MainActor
final class E2EAppAdapter: E2EApp {
    /// Far from every screen. The window subclass keeps AppKit from moving it back on screen.
    static let windowFrame = NSRect(x: -20_000, y: -20_000, width: 1280, height: 800)

    private(set) var lastOpenedPage: (any E2EPage)?
    private unowned let delegate: AppDelegate
    /// Every open page, by tab, so each window's tab events and policy questions reach their page. A page leaves
    /// when its tab closes.
    private var pages: [TabID: TabPage] = [:]

    init(delegate: AppDelegate) {
        self.delegate = delegate
        // The tabs' own leave prompts go to their pages instead of the screen. A reload prompt, or a prompt from a
        // tab with no page (a popup), leaves: tests only answer the prompts that closing a tab asks.
        BowLeavePrompts.answer { [weak self] tabID, isReload, answer in
            MainActor.assumeIsolated {
                guard !isReload, let page = self?.pages[TabID(rawValue: tabID)] else { return answer(true) }
                answer(page.answerLeavePrompt())
            }
        }
    }

    func openWindow(at url: URL, newProfile profile: E2EProfile?) async throws -> any E2EPage {
        let engineProfile = try profile.map {
            try delegate.engine.createProfile(id: ProfileID($0.id), isPersistent: $0.isPersistent)
        }
        let window = OffscreenBrowserWindow(
            contentRect: Self.windowFrame,
            styleMask: BrowserWindowController.styleMask,
            backing: .buffered,
            defer: false
        )
        let controller = delegate.openWindow(url: url, profile: engineProfile, window: window)
        controller.onTabEvent = { [weak self] tab, event in
            self?.pages[tab.tabID]?.tabDidReceive(event)
            if event == .closed { self?.pages[tab.tabID] = nil }
        }
        controller.navigationPolicy = { [weak self] tab, navigation in
            self?.pages[tab.tabID]?.decidePolicy(for: navigation) ?? .allow
        }
        guard let window = controller.window else { throw E2EError("the window controller has no window") }
        guard let tab = controller.selectedTab else { throw E2EError("the window opened without a tab") }
        // Made before the checks below wait, so the page hears every load event.
        let page = track(tab, in: controller)
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

    /// Spike S2: one off-screen window showing one page per existing profile, side by side, `urls[i]` in
    /// `profileIDs[i]`. Each page gets its own window controller (one profile each); every controller but the
    /// first keeps a window that is never ordered in, and its web view moves into the first window.
    func openSplitWindow(at urls: [URL], profileIDs: [String]) async throws -> [any E2EPage] {
        var controllers: [BrowserWindowController] = []
        var opened: [any E2EPage] = []
        for (url, id) in zip(urls, profileIDs) {
            guard let profile = delegate.engine.profile(id: ProfileID(id)) else {
                throw E2EError("no profile \(id)")
            }
            let window = OffscreenBrowserWindow(
                contentRect: Self.windowFrame,
                styleMask: BrowserWindowController.styleMask,
                backing: .buffered,
                defer: false
            )
            let controller = delegate.openWindow(url: url, profile: profile, window: window)
            controller.onTabEvent = { [weak self] tab, event in
                self?.pages[tab.tabID]?.tabDidReceive(event)
                if event == .closed { self?.pages[tab.tabID] = nil }
            }
            controller.navigationPolicy = { [weak self] tab, navigation in
                self?.pages[tab.tabID]?.decidePolicy(for: navigation) ?? .allow
            }
            guard let tab = controller.selectedTab else { throw E2EError("the window opened without a tab") }
            opened.append(track(tab, in: controller))
            controllers.append(controller)
        }
        guard let host = controllers.first?.window else { throw E2EError("no window") }
        let size = Self.windowFrame.size
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let width = (size.width / CGFloat(controllers.count)).rounded(.down)
        for (index, controller) in controllers.enumerated() {
            let webView = controller.webView
            controller.window?.contentView = NSView()
            webView.frame = NSRect(x: width * CGFloat(index), y: 0, width: width, height: size.height)
            webView.autoresizingMask = [.height]
            container.addSubview(webView)
        }
        host.contentView = container
        for controller in controllers {
            guard let window = controller.window else { continue }
            window.setFrame(window.frameRect(forContentRect: Self.windowFrame), display: false)
            try await Self.checkInvisible(window)
        }
        host.orderFrontRegardless()
        try await Self.checkInvisible(host)
        lastOpenedPage = opened.first
        return opened
    }

    func openTab(at url: URL, besides page: any E2EPage, select: Bool) throws -> any E2EPage {
        let controller = try Self.tabPage(page).controller
        let tab = controller.openTab(url: url, select: select)
        return track(tab, in: controller)
    }

    /// Creates the page for `tab` before the engine can report anything about it, which it does on later main
    /// thread tasks.
    private func track(_ tab: any EngineTab, in controller: BrowserWindowController) -> TabPage {
        let page = TabPage(tab: tab, controller: controller)
        pages[tab.tabID] = page
        return page
    }

    func select(_ page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        page.controller.select(page.tab)
        guard page.isShown else { throw E2EError("tab \(page.tab.tabID) is not shown after selecting it") }
    }

    func closeTab(_ page: any E2EPage) async throws -> Bool {
        let page = try Self.tabPage(page)
        return await page.controller.closeTab(page.tab)
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
        // Tests no longer hold their pages; releasing them here frees their DevTools sessions (and the Chromium
        // objects they hold) while the engine still runs.
        lastOpenedPage = nil
        pages.removeAll()
        NSApp.terminate(nil)
    }
}

/// E2EPage over one tab, fed its events and policy questions by the adapter, and a DevTools session on its browser.
@MainActor
private final class TabPage: E2EPage {
    let tab: any EngineTab
    let controller: BrowserWindowController
    private let devToolsSession: BowDevToolsSession
    /// Every finished main frame load, in order; load number n is `loads[n - 1]`.
    private var loads: [Result<Int, E2EError>] = []
    private var loadWaiters: [(load: Int, continuation: CheckedContinuation<Int, Error>)] = []
    private(set) var navigationEvents: [E2ENavigationEvent] = []
    var navigationPolicy: ((URL) -> Bool)?
    var leavePromptAnswer = true
    private(set) var leavePrompts = 0

    /// Counts a leave prompt the page's tab asked and returns its answer.
    func answerLeavePrompt() -> Bool {
        leavePrompts += 1
        return leavePromptAnswer
    }

    init(tab: any EngineTab, controller: BrowserWindowController) {
        self.tab = tab
        self.controller = controller
        devToolsSession = BowDevToolsSession(tabID: tab.tabID.rawValue)
    }

    var isShown: Bool { controller.webView.isShowing(tab) }
    /// The window's web view while it shows this tab; nil while another tab is shown or once the window is gone.
    var contentView: NSView? { isShown && controller.window != nil ? controller.webView : nil }
    var isClosed: Bool { tab.isClosed }
    var finishedLoads: Int { loads.count }

    func load(_ url: URL) {
        tab.load(url)
    }

    func decidePolicy(for navigation: EngineNavigation) -> NavigationPolicy {
        navigationPolicy?(navigation.url) == false ? .cancel : .allow
    }

    func tabDidReceive(_ event: TabEvent) {
        switch event {
        case .didStartNavigation(let navigation):
            navigationEvents.append(E2ENavigationEvent(kind: .start, url: navigation.url))
        case .didRedirect(let navigation):
            navigationEvents.append(E2ENavigationEvent(kind: .redirect, url: navigation.url))
        case .didCommit(let navigation):
            navigationEvents.append(E2ENavigationEvent(kind: .commit, url: navigation.url))
        case .didFinish(let navigation, let status):
            navigationEvents.append(E2ENavigationEvent(kind: .finish, url: navigation.url, code: status))
            loadFinished(.success(status))
        case .didFail(let navigation, let error):
            navigationEvents.append(E2ENavigationEvent(kind: .fail, url: navigation.url, code: error.code))
            let url = navigation.url.absoluteString
            loadFinished(.failure(E2EError("loading \(url) failed: \(error.code) \(error.description)")))
        case .closed:
            // Let go of a tab that closes during the run. At quit this comes too late (it runs after the engine
            // may have shut down), so quit() also drops every page, and with it the session, before quitting.
            devToolsSession.close()
            // A load awaited on a closed page never comes; fail now rather than at the step timeout.
            let waiters = loadWaiters
            loadWaiters.removeAll()
            for waiter in waiters { waiter.continuation.resume(throwing: E2EError("the tab closed")) }
        default:
            break
        }
    }

    func waitForLoad(after finishedLoads: Int) async throws -> Int {
        let load = finishedLoads + 1
        if load <= loads.count { return try loads[load - 1].get() }
        if tab.isClosed { throw E2EError("the tab closed") }
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
