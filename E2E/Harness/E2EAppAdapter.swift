import AppKit
import BowCore

// The only e2e file that knows the app's engine (the BowCore protocols the app drives it through), the window
// controllers and the bridge's BowDevToolsSession and BowLeavePrompts. When those change shape, rewrite this file
// to keep E2EApp and E2EPage working; tests stay as they are.

@MainActor
final class E2EAppAdapter {
    /// Far from every screen. The window subclass keeps AppKit from moving it back on screen.
    static let windowFrame = NSRect(x: -20_000, y: -20_000, width: 1280, height: 800)

    private unowned let delegate: AppDelegate
    /// Every open page, by tab, so each window's tab events and policy questions reach their page. A page leaves
    /// when its tab closes.
    private var pages: [TabID: TabPage] = [:]
    /// The running test's windows and pages, in the order they opened, and its own profile once a window used it.
    private var testControllers: [BrowserWindowController] = []
    private var testPages: [TabPage] = []
    private var testProfile: (any EngineProfile)?
    private var testProfileID = ""
    /// The token of the running test, nil between tests. Every app and page action a test takes carries its test's
    /// token and is refused unless it matches, so work left running by a test that ended (a timed-out step) cannot
    /// drive the app any further: a window it opened then would miss the cleanup and stay into later tests.
    private var activeToken: Int?

    /// Notices about the sidebar the app showed outside a test's own sidebar folders, recorded instead of shown so
    /// no alert waits for a click.
    private(set) var appSidebarNotices: [E2ESidebarNotice] = []

    init(delegate: AppDelegate) {
        self.delegate = delegate
        delegate.appFeatures.require(SidebarStores.self).presentNotice = { [weak self] notice, _ in
            self?.appSidebarNotices.append(E2ESidebarNotice(notice))
        }
        // The tabs' own leave prompts go to their pages instead of the screen. A reload prompt, or a prompt from a
        // tab with no page (a popup), leaves: tests only answer the prompts that closing a tab asks.
        BowLeavePrompts.answer { [weak self] tabID, isReload, answer in
            MainActor.assumeIsolated {
                guard !isReload, let page = self?.pages[TabID(rawValue: tabID)] else { return answer(true) }
                answer(page.answerLeavePrompt())
            }
        }
    }

    func openWindow(at url: URL, profile: E2EWindowProfile, token: Int) async throws -> any E2EPage {
        let delegate = delegate
        let engineProfile: (any EngineProfile)?
        switch profile {
        case .appDefault:
            // Named, so the window gets a sidebar of its own rather than the app's saved one.
            engineProfile = delegate.engine.profile(id: .default)
        case .test:
            if testProfile == nil { testProfile = try createProfile(id: testProfileID, isPersistent: false) }
            engineProfile = testProfile
        case .new(let profile):
            engineProfile = try createProfile(id: profile.id, isPersistent: profile.isPersistent)
        }
        return try await showWindow(token: token) { window in
            try delegate.openWindow(url: url, profile: engineProfile, window: window)
        }
    }

    /// Opens a browser window with `open` in a new off-screen window, tracks it and its shown tab for the test, and
    /// orders it in once it is known to stay invisible. Returns the page of its shown tab.
    private func showWindow(
        token: Int,
        open: (BrowserWindow) throws -> BrowserWindowController
    ) async throws -> TabPage {
        try await show(try open(Self.makeWindow()), token: token)
    }

    private static func makeWindow() -> BrowserWindow {
        OffscreenBrowserWindow(
            contentRect: Self.windowFrame,
            styleMask: BrowserWindowController.styleMask,
            backing: .buffered,
            defer: false
        )
    }

    /// Tracks the window of `controller` and its shown tab for the test, and orders it in once it is known to stay
    /// invisible. Returns the page of its shown tab.
    private func show(_ controller: BrowserWindowController, token: Int) async throws -> TabPage {
        testControllers.append(controller)
        controller.onTabEvent = { [weak self, unowned controller] tab, event in
            if case .stateChanged = event, let row = Self.sidebarRow(of: tab, in: controller) {
                self?.pages[tab.tabID]?.sidebarRowHistory.append(row)
            }
            self?.pages[tab.tabID]?.tabDidReceive(event)
            if event == .closed { self?.pages[tab.tabID] = nil }
        }
        controller.navigationPolicy = { [weak self] tab, navigation in
            self?.pages[tab.tabID]?.decidePolicy(for: navigation) ?? .allow
        }
        guard let window = controller.window else { throw E2EError("the window controller has no window") }
        guard let tab = controller.selectedTab else { throw E2EError("the window opened without a tab") }
        // Made before the checks below wait, so the page hears every load event.
        let page = track(tab, in: controller, token: token)
        // Creating a titled window moves it onto a screen; put it back where it belongs.
        window.setFrame(window.frameRect(forContentRect: Self.windowFrame), display: false)
        // Check before ordering the window in, so a broken setup fails instead of showing a window.
        try await Self.checkInvisible(window)
        // The test may have ended while the check waited, and the cleanup only closes windows that show.
        guard activeToken == token else {
            // Closed the way the close button does, so the window's tabs and browsers close too.
            window.performClose(nil)
            throw E2EError("refused to show a window: its test had already ended", reason: .testEnded)
        }
        // Ordered in without activating the app or becoming key, so it composites like a visible window.
        window.orderFrontRegardless()
        try await Self.checkInvisible(window)
        return page
    }

    private func createProfile(id: String, isPersistent: Bool) throws -> any EngineProfile {
        do {
            return try delegate.engine.createProfile(id: ProfileID(id), isPersistent: isPersistent)
        } catch EngineError.profileExists(let existing) {
            throw E2EError("the profile ID \(id) is taken by \(existing.rawValue)", reason: .profileTaken)
        } catch {
            throw E2EError("cannot create the profile \(id): \(error)")
        }
    }

    // MARK: The runner's side: one test at a time

    /// Starts a test and returns the app as that test sees it: its windows and pages are tracked from now on, and
    /// its first `.test` window creates a fresh in-memory profile named after `index`. What the returned app and
    /// its pages do is refused with an error once `endTest()` is called.
    func beginTest(index: Int) -> any E2EApp {
        testControllers.removeAll()
        testPages.removeAll()
        testProfile = nil
        testProfileID = "e2e-test-\(index)"
        activeToken = index
        return TestApp(adapter: self, token: index)
    }

    /// Ends the running test: from now on its app and pages refuse every action.
    func endTest() {
        activeToken = nil
    }

    /// Throws unless `token` is the running test's.
    fileprivate func requireActive(_ token: Int, _ action: String) throws {
        guard activeToken == token else {
            throw E2EError("refused to \(action): its test had already ended", reason: .testEnded)
        }
    }

    /// How many browsers the engine has open or is creating, popups included.
    var openBrowserCount: Int { BowOpenBrowsers.count() }

    /// The page to screenshot as evidence for the running test: the page it opened last while its window still
    /// shows it, or else the shown tab of the test's last window that is still open.
    var evidencePage: (any E2EPage)? {
        if let page = testPages.last(where: { $0.contentView != nil }) { return page }
        for controller in testControllers.reversed() where controller.window?.isVisible == true {
            if let tab = controller.selectedTab, let page = pages[tab.tabID], page.contentView != nil { return page }
        }
        return nil
    }

    /// Closes every window the running test opened, leaving each page without asking (leave prompts answer
    /// leave), then waits until the engine has no more browsers open than `baseline` (the count before the test),
    /// popups included, or `timeout` runs out. Returns nil when nothing is left, or what is left.
    func closeTestWindows(timeout: TimeInterval, baseline: Int) async -> String? {
        let controllers = testControllers
        testControllers.removeAll()
        testPages.removeAll()
        for page in pages.values where controllers.contains(where: { $0 === page.controller }) {
            page.leavePromptAnswer = true
        }
        for controller in controllers where controller.window?.isVisible == true {
            controller.window?.performClose(nil)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let windows = controllers.filter { $0.window?.isVisible == true }.count
            let browsers = openBrowserCount - baseline
            if windows == 0 && browsers <= 0 { return nil }
            if Date() >= deadline {
                return
                    "windows=\(windows) browsers=\(browsers) still open \(Int(timeout)) s after closing the test's windows"
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func openTab(at url: URL, besides page: any E2EPage, select: Bool, token: Int) throws -> any E2EPage {
        let controller = try Self.tabPage(page).controller
        guard let tab = controller.openTab(url: url, select: select) else {
            throw E2EError("the window opened no tab for \(url.absoluteString)")
        }
        return track(tab, in: controller, token: token)
    }

    /// Creates the page for `tab` before the engine can report anything about it, which it does on later main
    /// thread tasks.
    private func track(_ tab: any EngineTab, in controller: BrowserWindowController, token: Int) -> TabPage {
        let page = TabPage(tab: tab, controller: controller, adapter: self, token: token)
        pages[tab.tabID] = page
        testPages.append(page)
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

    func click(_ button: E2EToolbarButton, in page: any E2EPage) throws {
        let control = try Self.toolbarControl(button, in: page)
        guard control.isEnabled else { throw E2EError("the \(button.rawValue) button is disabled") }
        control.performClick(nil)
    }

    func toolbarButton(_ button: E2EToolbarButton, in page: any E2EPage) throws -> E2EToolbarButtonState {
        let control = try Self.toolbarControl(button, in: page)
        return E2EToolbarButtonState(isEnabled: control.isEnabled, label: control.accessibilityLabel() ?? "")
    }

    private static func toolbarControl(_ button: E2EToolbarButton, in page: any E2EPage) throws -> NSButton {
        let controller = try tabPage(page).controller
        let item: NavigationToolbar.Item =
            switch button {
            case .back: .back
            case .forward: .forward
            case .reload: .reload
            }
        let control = controller.navigationToolbar.button(item)
        // The button must really be in the window's toolbar, not just exist.
        guard let window = controller.window, control.window === window,
            window.toolbar?.items.contains(where: { $0.view === control }) == true
        else {
            throw E2EError("the \(button.rawValue) button is not in the window's toolbar")
        }
        return control
    }

    /// Finds the menu item with the shortcut and sends its action the way AppKit does for a key press: to the first
    /// object in the window's responder chain (then its delegate) that handles it, after that object validates
    /// the item. The e2e window never becomes key, so the window is named here instead of AppKit finding the key
    /// window.
    func press(_ shortcut: E2EShortcut, in page: any E2EPage) throws {
        let controller = try Self.tabPage(page).controller
        guard let window = controller.window else { throw E2EError("the page has no window") }
        guard let item = NSApp.mainMenu.flatMap({ Self.menuItem(shortcut.key, in: $0) }), let action = item.action
        else {
            throw E2EError("no menu item has the shortcut Cmd+\(shortcut.key)")
        }
        var responder: NSResponder? = window.firstResponder
        var target: AnyObject?
        while let current = responder, target == nil {
            if current.responds(to: action) { target = current }
            responder = current.nextResponder
        }
        if target == nil, let delegate = window.delegate, delegate.responds(to: action) { target = delegate }
        guard let target else { throw E2EError("nothing in the window handles \(item.title)") }
        if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
            throw E2EError("\(item.title) (Cmd+\(shortcut.key)) is disabled")
        }
        NSApp.sendAction(action, to: target, from: item)
    }

    private static func menuItem(_ key: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command { return item }
            if let submenu = item.submenu, let found = menuItem(key, in: submenu) { return found }
        }
        return nil
    }

    func activityTime(of page: any E2EPage) throws -> Date? {
        let page = try Self.tabPage(page)
        let controller = page.controller
        guard let id = controller.modelID(of: page.tab), let item = controller.sidebarItemID(for: id) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar item")
        }
        return controller.appFeatures.require(TabActivityLog.self).lastActive(item)
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

    private var downloadsWindow: DownloadsWindowController?

    /// The downloads window, opened off screen the first time.
    private func downloadsList() async throws -> DownloadsWindowController {
        if let downloadsWindow { return downloadsWindow }
        // Every browser window shares the app's services; a test opens one before reading its downloads.
        guard let appFeatures = testControllers.first?.appFeatures else {
            throw E2EError("the downloads window needs a browser window open first")
        }
        let frame = NSRect(x: -20_000, y: -21_000, width: 480, height: 360)
        let window = OffscreenBrowserWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let controller = appFeatures.require(DownloadsCenter.self).openWindow(in: window)
        window.setFrame(window.frameRect(forContentRect: frame), display: false)
        try await Self.checkInvisible(window)
        window.orderFrontRegardless()
        try await Self.checkInvisible(window)
        downloadsWindow = controller
        return controller
    }

    func downloads() async throws -> [E2EDownload] {
        let list = try await downloadsList()
        return list.rows.enumerated().map { index, entry in
            let row = list.rowView(at: index)
            return E2EDownload(
                id: "\(entry.profileID)/\(entry.item.id)",
                fileName: row?.nameLabel.stringValue ?? "",
                state: entry.item.state.rawValue,
                status: row?.statusLabel.stringValue ?? "",
                receivedBytes: entry.item.receivedBytes,
                path: entry.item.destination
            )
        }
    }

    func press(_ button: E2EDownload.Button, of download: E2EDownload) async throws {
        let list = try await downloadsList()
        guard let index = list.rows.firstIndex(where: { "\($0.profileID)/\($0.item.id)" == download.id }),
            let row = list.rowView(at: index)
        else { throw E2EError("no row for download \(download.id)") }
        let control = button == .pauseOrResume ? row.pauseButton : row.cancelButton
        guard !control.isHidden else {
            throw E2EError("the \(control.title) button of \(download.fileName) is hidden")
        }
        control.performClick(nil)
    }

    func quit() {
        // Tests no longer hold their pages; releasing them here frees their DevTools sessions (and the Chromium
        // objects they hold) while the engine still runs.
        testControllers.removeAll()
        testPages.removeAll()
        pages.removeAll()
        NSApp.terminate(nil)
    }
}

/// The app as one test sees it: every action carries the test's token, so the adapter refuses it once the test has
/// ended.
@MainActor
private final class TestApp: E2EApp {
    fileprivate unowned let adapter: E2EAppAdapter
    fileprivate let token: Int

    init(adapter: E2EAppAdapter, token: Int) {
        self.adapter = adapter
        self.token = token
    }

    func openWindow(at url: URL, profile: E2EWindowProfile) async throws -> any E2EPage {
        try adapter.requireActive(token, "open a window")
        return try await adapter.openWindow(at: url, profile: profile, token: token)
    }

    func openTab(at url: URL, besides page: any E2EPage, select: Bool) throws -> any E2EPage {
        try adapter.requireActive(token, "open a tab")
        return try adapter.openTab(at: url, besides: page, select: select, token: token)
    }

    func select(_ page: any E2EPage) throws {
        try adapter.requireActive(token, "select a tab")
        try adapter.select(page)
    }

    func closeTab(_ page: any E2EPage) async throws -> Bool {
        try adapter.requireActive(token, "close a tab")
        return try await adapter.closeTab(page)
    }

    func closeWindow(of page: any E2EPage) async throws {
        try adapter.requireActive(token, "close a window")
        try await adapter.closeWindow(of: page)
    }

    func click(_ button: E2EToolbarButton, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click \(button.rawValue)")
        try adapter.click(button, in: page)
    }

    func toolbarButton(_ button: E2EToolbarButton, in page: any E2EPage) throws -> E2EToolbarButtonState {
        try adapter.toolbarButton(button, in: page)
    }

    func press(_ shortcut: E2EShortcut, in page: any E2EPage) throws {
        try adapter.requireActive(token, "press Cmd+\(shortcut.key)")
        try adapter.press(shortcut, in: page)
    }

    func downloads() async throws -> [E2EDownload] {
        try adapter.requireActive(token, "read the downloads window")
        return try await adapter.downloads()
    }

    func press(_ button: E2EDownload.Button, of download: E2EDownload) async throws {
        try adapter.requireActive(token, "press a download's \(button) button")
        try await adapter.press(button, of: download)
    }

    func quit() {
        // The runner quits once every test has ended; a test that has ended must not quit early.
        guard (try? adapter.requireActive(token, "quit")) != nil else { return }
        adapter.quit()
    }
}

extension TestApp: E2ESidebarApp {
    func sidebarRows(of page: any E2EPage) throws -> [E2ESidebarRow] {
        try adapter.sidebarRows(of: page)
    }

    func sidebarRowHistory(of page: any E2EPage) -> [E2ESidebarRow] {
        adapter.sidebarRowHistory(of: page)
    }

    func clickSidebarRow(of page: any E2EPage) throws {
        try adapter.requireActive(token, "click a sidebar row")
        try adapter.clickSidebarRow(of: page)
    }

    func clickSidebarClose(of page: any E2EPage) throws {
        try adapter.requireActive(token, "click a sidebar close button")
        try adapter.clickSidebarClose(of: page)
    }

    func clickNewTab(besides page: any E2EPage, opening url: URL) throws -> any E2EPage {
        try adapter.requireActive(token, "click the New Tab button")
        return try adapter.clickNewTab(besides: page, opening: url, token: token)
    }

    func chooseMenuItem(commandKey key: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose the menu item for Command-\(key)")
        try adapter.chooseMenuItem(commandKey: key, in: page)
    }

    func moveTab(_ page: any E2EPage, to index: Int) throws {
        try adapter.requireActive(token, "move a tab")
        try adapter.moveTab(page, to: index)
    }
}

extension TestApp: E2EZonesApp {
    func sidebarOutline(of page: any E2EPage) throws -> [String] {
        try adapter.sidebarOutline(of: page)
    }

    func sidebarZone(of page: any E2EPage) throws -> String? {
        try adapter.sidebarZone(of: page)
    }

    func dragTab(_ page: any E2EPage, onRow row: Int?, childIndex: Int) throws {
        try adapter.requireActive(token, "drag a tab")
        try adapter.dragTab(page, onRow: row, childIndex: childIndex)
    }
}

/// E2EPage over one tab, fed its events and policy questions by the adapter, and a DevTools session on its browser.
@MainActor
private final class TabPage: E2EPage {
    let tab: any EngineTab
    let controller: BrowserWindowController
    /// The adapter and the token of the test that opened the page, which page actions must still match.
    private unowned let adapter: E2EAppAdapter
    private let token: Int
    private let devToolsSession: BowDevToolsSession
    /// Every finished main frame load, in order; load number n is `loads[n - 1]`.
    private var loads: [Result<Int, E2EError>] = []
    private var loadWaiters: [(load: Int, continuation: CheckedContinuation<Int, Error>)] = []
    private(set) var navigationEvents: [E2ENavigationEvent] = []
    /// The tab's sidebar row after each state change, recorded by the adapter.
    var sidebarRowHistory: [E2ESidebarRow] = []
    var navigationPolicy: ((URL) -> Bool)?
    var leavePromptAnswer = true
    private(set) var leavePrompts = 0
    /// The last find result the tab reported.
    private(set) var lastFindResult: E2EFindResult?

    /// Counts a leave prompt the page's tab asked and returns its answer.
    func answerLeavePrompt() -> Bool {
        leavePrompts += 1
        return leavePromptAnswer
    }

    init(tab: any EngineTab, controller: BrowserWindowController, adapter: E2EAppAdapter, token: Int) {
        self.tab = tab
        self.controller = controller
        self.adapter = adapter
        self.token = token
        devToolsSession = BowDevToolsSession(tabID: tab.tabID.rawValue)
    }

    var isShown: Bool { controller.webView.isShowing(tab) }
    /// The window's web view while it shows this tab; nil while another tab is shown or once the window is gone.
    var contentView: NSView? { isShown && controller.window != nil ? controller.webView : nil }
    var isClosed: Bool { tab.isClosed }
    var finishedLoads: Int { loads.count }

    var permissionPrompt: E2EPermissionPrompt? {
        guard isShown, let prompt = controller.permissionPrompts?.visiblePrompt else { return nil }
        return E2EPermissionPrompt(
            kinds: Set(prompt.request.kinds.map(\.rawValue)),
            message: prompt.message,
            frame: prompt.frame
        ) { [weak self, weak prompt] allow in
            try self?.requireActive(allow ? "allow a permission" : "block a permission")
            (allow ? prompt?.allowButton : prompt?.blockButton)?.performClick(nil)
        }
    }

    /// Throws unless the test that opened the page is still running.
    func requireActive(_ action: String) throws {
        try adapter.requireActive(token, action)
    }

    func load(_ url: URL) throws {
        try requireActive("load \(url.absoluteString)")
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
        case .findResult(let result):
            lastFindResult = E2EFindResult(
                matches: result.matchCount, active: result.activeMatch, isFinal: result.isFinal)
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

    func openFindBar() throws -> any E2EFindBar {
        try requireActive("open the find bar")
        guard let window = controller.window else { throw E2EError("the page has no window") }
        guard let item = Self.menuItem(keyEquivalent: "f", in: NSApp.mainMenu) else {
            throw E2EError("no menu item has the key equivalent Cmd+F")
        }
        guard let action = item.action else { throw E2EError("the Cmd+F menu item has no action") }
        // The menu sends its action along the key window's responder chain. The e2e window is never key, so send
        // it along this window's chain the same way.
        let responder: NSResponder = window.firstResponder ?? window
        guard responder.tryToPerform(action, with: item) else {
            throw E2EError("nothing in the window's responder chain handles \(action)")
        }
        let bar = WindowFindBar(page: self, window: window)
        guard bar.isShown else { throw E2EError("the find bar did not show") }
        return bar
    }

    private static func menuItem(keyEquivalent: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.keyEquivalent == keyEquivalent, item.keyEquivalentModifierMask == .command { return item }
            if let found = menuItem(keyEquivalent: keyEquivalent, in: item.submenu) { return found }
        }
        return nil
    }

    func waitForLoad(after finishedLoads: Int) async throws -> Int {
        let load = finishedLoads + 1
        if load <= loads.count { return try loads[load - 1].get() }
        if tab.isClosed { throw E2EError("the tab closed") }
        return try await withCheckedThrowingContinuation { loadWaiters.append((load, $0)) }
    }

    /// DevTools methods that only read the page, which the runner still calls after a test ended (for its
    /// fail.png), so they are not refused like the rest.
    private static let readOnlyDevToolsMethods: Set<String> = ["Page.captureScreenshot"]

    func devTools(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        if !Self.readOnlyDevToolsMethods.contains(method) { try requireActive("call \(method)") }
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

/// E2EFindBar over a window controller's find bar. Keys go to the window's first responder as key events, which is
/// where the window would deliver them if it were key.
@MainActor
private final class WindowFindBar: E2EFindBar {
    private let page: TabPage
    private let window: NSWindow
    private var findBar: FindBar { page.controller.findBar }

    init(page: TabPage, window: NSWindow) {
        self.page = page
        self.window = window
    }

    var isShown: Bool { !findBar.isHidden && findBar.window === window }
    var hasKeyboard: Bool {
        guard let editor = findBar.field.currentEditor() else { return false }
        return window.firstResponder === editor
    }
    var count: String { findBar.countLabel.stringValue }
    var text: String { findBar.text }
    var lastResult: E2EFindResult? { page.lastFindResult }

    func type(_ text: String) throws {
        for character in text {
            try send(String(character), keyCode: 0, modifiers: [])
        }
    }

    func press(_ key: E2EFindKey) throws {
        switch key {
        case .enter: try send("\r", keyCode: 36, modifiers: [])
        case .shiftEnter: try send("\r", keyCode: 36, modifiers: .shift)
        case .escape: try send("\u{1b}", keyCode: 53, modifiers: [])
        }
    }

    private func send(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws {
        try page.requireActive("press keys in the find bar")
        guard hasKeyboard, let responder = window.firstResponder else {
            throw E2EError("the keyboard is not in the find bar's field")
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                )
            else { throw E2EError("cannot make a key event for \(characters.debugDescription)") }
            if type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
        }
    }
}

/// A DevTools result handed from the session's completion to the awaiting page. Both run on the main thread
/// and the dictionary is never touched elsewhere, so passing it along is safe.
private struct MainThreadResult: @unchecked Sendable {
    let value: [String: Any]
}

// The sidebar and tab commands over the window controller and its SidebarView. The test's app (TestApp) offers
// them to the test, after checking that the test is still running.
extension E2EAppAdapter {
    func sidebarRows(of page: any E2EPage) throws -> [E2ESidebarRow] {
        let controller = try Self.tabPage(page).controller
        return controller.tabs.compactMap { Self.sidebarRow(of: $0, in: controller) }
    }

    func sidebarRowHistory(of page: any E2EPage) -> [E2ESidebarRow] {
        (page as? TabPage)?.sidebarRowHistory ?? []
    }

    /// The row of `tab` as the sidebar draws it, made if the outline has not laid it out yet.
    fileprivate static func sidebarRow(of tab: any EngineTab, in controller: BrowserWindowController)
        -> E2ESidebarRow?
    {
        guard let id = controller.modelID(of: tab), let item = controller.sidebarItemID(for: id),
            let row = controller.sidebar.row(for: item)
        else { return nil }
        let outline = controller.sidebar.outlineView
        guard let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabSidebarRow else {
            return nil
        }
        return E2ESidebarRow(
            title: view.titleField.stringValue,
            isLoading: view.isLoading,
            hasFavicon: view.hasFavicon,
            isActive: outline.rowView(atRow: row, makeIfNecessary: true)?.isSelected ?? false
        )
    }

    /// The sidebar item of `page`'s tab.
    private static func sidebarItem(of page: TabPage) throws -> SidebarItemID {
        guard let id = page.controller.modelID(of: page.tab), let item = page.controller.sidebarItemID(for: id) else {
            throw E2EError("tab \(page.tab.tabID) is not in its window's sidebar")
        }
        return item
    }

    func clickSidebarRow(of page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        guard let row = page.controller.sidebar.row(for: try Self.sidebarItem(of: page)) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        // What the outline's click action does with the clicked row.
        page.controller.sidebar.clickRow(row)
    }

    func clickSidebarClose(of page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        guard let view = page.controller.sidebar.rowView(for: try Self.sidebarItem(of: page)) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        guard !view.closeButton.isHidden else { throw E2EError("the row's close button is not showing") }
        try Self.click(view.closeButton)
    }

    func clickNewTab(besides page: any E2EPage, opening url: URL, token: Int) throws -> any E2EPage {
        let controller = try Self.tabPage(page).controller
        let before = Set(controller.tabs.map(\.tabID))
        controller.newTabURL = url
        try Self.click(controller.sidebar.newTabButton)
        guard let tab = controller.tabs.first(where: { !before.contains($0.tabID) }) else {
            throw E2EError("the New Tab button opened no tab")
        }
        return track(tab, in: controller, token: token)
    }

    /// Sends `button`'s action to its target, as a click on it ends up doing. `performClick(_:)` is not used: it
    /// runs the run loop while it shows the button pressed, so the engine's events for a tab the click opens
    /// would arrive before the test could track the tab.
    private static func click(_ button: NSButton) throws {
        guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor, let action = button.action,
            NSApp.sendAction(action, to: button.target, from: button)
        else {
            throw E2EError("the button \"\(button.accessibilityLabel() ?? button.title)\" cannot be clicked")
        }
    }

    func chooseMenuItem(commandKey key: String, in page: any E2EPage) throws {
        let controller = try Self.tabPage(page).controller
        guard let item = Self.menuItem(commandKey: key, in: NSApp.mainMenu), let action = item.action else {
            throw E2EError("no menu item has the shortcut Command-\(key)")
        }
        // An e2e window never becomes key, so the item is sent to the page's window rather than the key window.
        let target: Any? = controller.responds(to: action) ? controller : controller.window
        guard NSApp.sendAction(action, to: target, from: item) else {
            throw E2EError("the menu item \"\(item.title)\" did nothing")
        }
    }

    private static func menuItem(commandKey key: String, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.keyEquivalent == key, item.keyEquivalentModifierMask == .command { return item }
            if let found = menuItem(commandKey: key, in: item.submenu) { return found }
        }
        return nil
    }

    func moveTab(_ page: any E2EPage, to index: Int) throws {
        let page = try Self.tabPage(page)
        guard let id = page.controller.modelID(of: page.tab) else {
            throw E2EError("tab \(page.tab.tabID) is not in its window")
        }
        guard page.controller.sidebarFeature.dropTab(id, atTabIndex: index) else {
            throw E2EError("the sidebar refused to move the tab to \(index)")
        }
    }

    func sidebarOutline(of page: any E2EPage) throws -> [String] {
        let sidebar = try Self.tabPage(page).controller.sidebar
        return sidebar.rowKinds().enumerated().map { row, kind in
            if let section = kind.section { return section.zone?.rawValue ?? "divider" }
            let view = sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            return (view as? TabSidebarRow)?.titleField.stringValue
                ?? (view as? SidebarGroupRow)?.titleField.stringValue ?? "?"
        }
    }

    func sidebarZone(of page: any E2EPage) throws -> String? {
        let page = try Self.tabPage(page)
        return page.controller.sidebar.zone(of: try Self.sidebarItem(of: page))?.rawValue
    }

    func dragTab(_ page: any E2EPage, onRow row: Int?, childIndex: Int) throws {
        let page = try Self.tabPage(page)
        let item = try Self.sidebarItem(of: page)
        // The outline's own drop routing: the proposal (with its retargeted gap), then the accepted drop.
        guard page.controller.sidebar.dragItem(item, onRow: row, childIndex: childIndex) else {
            let place = row.map { "row \($0)" } ?? "between sections"
            throw E2EError("the sidebar refused to drop the tab on \(place) at \(childIndex)")
        }
    }
}

// The window features the adapter reaches into. Every window has each of them (`WindowFeatures.all`).
extension BrowserWindowController {
    fileprivate var sidebarFeature: SidebarFeature { feature(SidebarFeature.self)! }
    fileprivate var sidebar: SidebarView { sidebarFeature.sidebar }
    fileprivate var findBar: FindBar { feature(FindFeature.self)!.findBar }
    fileprivate var permissionPrompts: PermissionPrompts? { feature(PermissionsFeature.self)?.prompts }
    fileprivate var navigationToolbar: NavigationToolbar { feature(NavigationFeature.self)!.toolbar }
}

// The sidebar store and tab creation over the window controller's `SidebarStore` and the app delegate's link
// handling. The test's app (TestApp) offers them to the test, after checking that the test is still running.
extension E2EAppAdapter {
    func sidebarItemCount(of page: any E2EPage) throws -> Int {
        try Self.tabPage(page).controller.store.graph.contentItemCount
    }

    func relaunchSidebar(of page: any E2EPage, token: Int) async throws -> E2ERelaunchedSidebar {
        let file = try Self.tabPage(page).controller.store.fileURL
        try await closeWindow(of: page)
        let store: SidebarStore
        do {
            store = try SidebarStore(fileURL: file)
        } catch {
            throw E2EError("cannot read the sidebar back from \(file.lastPathComponent): \(error)")
        }
        let delegate = delegate
        let shown = try await showWindow(token: token) { window in
            try delegate.openWindow(url: nil, store: store, window: window)
        }
        let controller = shown.controller
        return E2ERelaunchedSidebar(
            page: shown,
            itemCount: store.graph.contentItemCount,
            rowCount: controller.tabList.count,
            loadedTabCount: controller.tabs.count
        )
    }

    func openExternalLink(_ url: URL, token: Int) throws -> any E2EPage {
        let before = Set(pages.keys)
        guard let controller = delegate.openLink(url) else { throw E2EError("the link opened no tab") }
        guard let tab = controller.tabs.first(where: { !before.contains($0.tabID) }) else {
            throw E2EError("the link's window has no new tab")
        }
        return track(tab, in: controller, token: token)
    }

    func tabProfileID(of page: any E2EPage) throws -> String {
        try Self.tabPage(page).tab.profileID.rawValue
    }
}

extension TestApp: E2EActivityApp {
    func activityTime(of page: any E2EPage) throws -> Date? {
        try adapter.activityTime(of: page)
    }
}

// Opening the app's own sidebar from a folder of the test's, the way launch does, and links from other apps.
extension E2EAppAdapter {
    func openSavedSidebar(
        dataFolder: URL, windowFolder: URL, url: URL, ownSidebar: Bool, token: Int
    ) async throws -> E2ESidebarOpening {
        let stores = SidebarStores(dataDirectory: dataFolder, windowFolderParent: windowFolder)
        let log = NoticeLog()
        stores.presentNotice = { notice, _ in
            log.notices.append(E2ESidebarNotice(notice))
        }
        let profile = ownSidebar ? delegate.engine.profile(id: .default) : nil
        let controller: BrowserWindowController
        do {
            controller = try delegate.openWindow(
                url: url, profile: profile, window: Self.makeWindow(), sidebarStores: stores)
        } catch {
            // As the app does when a window cannot open: the notice shows instead.
            stores.present(error, in: nil)
            return E2ESidebarOpening(page: nil, opened: false, notices: log.notices)
        }
        guard controller.selectedTab != nil else {
            // A window with no tab has no browser; closed the way its close button does.
            controller.window?.performClose(nil)
            return E2ESidebarOpening(page: nil, opened: true, notices: log.notices)
        }
        let page = try await show(controller, token: token)
        return E2ESidebarOpening(page: page, opened: true, notices: log.notices)
    }

    func deliverLinkFromOtherApp(_ url: URL) {
        delegate.application(NSApp, open: [url])
    }
}

@MainActor
private final class NoticeLog {
    var notices: [E2ESidebarNotice] = []
}

extension E2ESidebarNotice {
    init(_ notice: SidebarNotice) {
        self.init(kind: notice.kind.rawValue, message: notice.message, detail: notice.detail)
    }
}

extension TestApp: E2EStoreApp {
    func openSavedSidebar(inDataFolder dataFolder: URL, windowFolder: URL, url: URL, ownSidebar: Bool)
        async throws -> E2ESidebarOpening
    {
        try adapter.requireActive(token, "open a saved sidebar")
        return try await adapter.openSavedSidebar(
            dataFolder: dataFolder, windowFolder: windowFolder, url: url, ownSidebar: ownSidebar, token: token)
    }

    func deliverLinkFromOtherApp(_ url: URL) throws {
        try adapter.requireActive(token, "deliver a link from another app")
        adapter.deliverLinkFromOtherApp(url)
    }

    var appSidebarNotices: [E2ESidebarNotice] { adapter.appSidebarNotices }

    func sidebarItemCount(of page: any E2EPage) throws -> Int {
        try adapter.sidebarItemCount(of: page)
    }

    func relaunchSidebar(of page: any E2EPage) async throws -> E2ERelaunchedSidebar {
        try adapter.requireActive(token, "relaunch a sidebar")
        return try await adapter.relaunchSidebar(of: page, token: token)
    }

    func openExternalLink(_ url: URL) throws -> any E2EPage {
        try adapter.requireActive(token, "open a link from another app")
        return try adapter.openExternalLink(url, token: token)
    }

    func tabProfileID(of page: any E2EPage) throws -> String {
        try adapter.tabProfileID(of: page)
    }
}
