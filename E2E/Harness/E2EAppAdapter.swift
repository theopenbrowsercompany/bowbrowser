import AppKit
import BowCore

// The only e2e file that knows the app's engine (the BowCore protocols the app drives it through), the window
// controllers and the bridge's BowDevToolsSession and BowLeavePrompts. When those change shape, rewrite this file
// to keep E2EApp and E2EPage working; tests stay as they are.

@MainActor
final class E2EAppAdapter: E2EApp {
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

    func openWindow(at url: URL, profile: E2EWindowProfile) async throws -> any E2EPage {
        let engineProfile: (any EngineProfile)?
        switch profile {
        case .appDefault:
            engineProfile = nil
        case .test:
            if testProfile == nil { testProfile = try createProfile(id: testProfileID, isPersistent: false) }
            engineProfile = testProfile
        case .new(let profile):
            engineProfile = try createProfile(id: profile.id, isPersistent: profile.isPersistent)
        }
        let window = OffscreenBrowserWindow(
            contentRect: Self.windowFrame,
            styleMask: BrowserWindowController.styleMask,
            backing: .buffered,
            defer: false
        )
        let controller = delegate.openWindow(url: url, profile: engineProfile, window: window)
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
        let page = track(tab, in: controller)
        // Creating a titled window moves it onto a screen; put it back where it belongs.
        window.setFrame(window.frameRect(forContentRect: Self.windowFrame), display: false)
        // Check before ordering the window in, so a broken setup fails instead of showing a window.
        try await Self.checkInvisible(window)
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

    /// Starts a test: its windows and pages are tracked from now on, and its first `.test` window creates a fresh
    /// in-memory profile named after `index`.
    func beginTest(index: Int) {
        testControllers.removeAll()
        testPages.removeAll()
        testProfile = nil
        testProfileID = "e2e-test-\(index)"
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
        testControllers.removeAll()
        testPages.removeAll()
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

    var permissionPrompt: E2EPermissionPrompt? {
        guard isShown, let prompt = controller.permissionPrompts.visiblePrompt else { return nil }
        return E2EPermissionPrompt(
            kinds: Set(prompt.request.kinds.map(\.rawValue)),
            message: prompt.message,
            frame: prompt.frame
        ) { [weak prompt] allow in
            (allow ? prompt?.allowButton : prompt?.blockButton)?.performClick(nil)
        }
    }

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

// The sidebar and tab commands over the window controller and its TabSidebarView.
extension E2EAppAdapter: E2ESidebarApp {
    func sidebarRows(of page: any E2EPage) throws -> [E2ESidebarRow] {
        let controller = try Self.tabPage(page).controller
        return controller.tabs.compactMap { Self.sidebarRow(of: $0, in: controller) }
    }

    func sidebarRowHistory(of page: any E2EPage) -> [E2ESidebarRow] {
        (page as? TabPage)?.sidebarRowHistory ?? []
    }

    /// The row of `tab` as the sidebar draws it, made if the table has not laid it out yet.
    fileprivate static func sidebarRow(of tab: any EngineTab, in controller: BrowserWindowController)
        -> E2ESidebarRow?
    {
        guard let id = controller.modelID(of: tab), let row = controller.sidebar.tabList.index(of: id) else {
            return nil
        }
        let table = controller.sidebar.tableView
        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabSidebarRow else {
            return nil
        }
        return E2ESidebarRow(
            title: view.titleField.stringValue,
            isLoading: view.isLoading,
            hasFavicon: view.hasFavicon,
            isActive: table.rowView(atRow: row, makeIfNecessary: true)?.isSelected ?? false
        )
    }

    func clickSidebarRow(of page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        let sidebar = page.controller.sidebar
        guard let id = page.controller.modelID(of: page.tab), let row = sidebar.tabList.index(of: id) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        // What the table's click action does with the clicked row.
        sidebar.clickRow(row)
    }

    func clickSidebarClose(of page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        guard let id = page.controller.modelID(of: page.tab), let view = page.controller.sidebar.rowView(for: id)
        else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        guard !view.closeButton.isHidden else { throw E2EError("the row's close button is not showing") }
        try Self.click(view.closeButton)
    }

    func clickNewTab(besides page: any E2EPage, opening url: URL) throws -> any E2EPage {
        let controller = try Self.tabPage(page).controller
        let before = Set(controller.tabs.map(\.tabID))
        controller.newTabURL = url
        try Self.click(controller.sidebar.newTabButton)
        guard let tab = controller.tabs.first(where: { !before.contains($0.tabID) }) else {
            throw E2EError("the New Tab button opened no tab")
        }
        return track(tab, in: controller)
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
        page.controller.sidebar(page.controller.sidebar, move: id, to: index)
    }
}
