import AppKit
import BowCore

/// A browser window: a sidebar listing its tabs on the left, and one host view that shows the active tab. The
/// order of the tabs and which one is active live in a BowCore `TabList`; the window keeps one engine tab per
/// entry. It reaches the engine only through the BowCore protocols, and is the delegate of each of its tabs.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, EngineTabDelegate,
    TabSidebarDelegate
{
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    /// The size, in pixels, site icons are loaded at for the sidebar (16 points on a Retina screen).
    private static let faviconPixelSize = 32

    /// Shows the selected tab. Switching tabs shows another tab here; pages are never reloaded by a switch.
    let webView: BowWebView
    /// The sidebar listing the window's tabs.
    let sidebar: TabSidebarView
    /// The find in page bar, floating over the page's top right corner while shown (Cmd+F).
    let findBar = FindBar()
    /// The tab the find bar searches in while it is shown; the bar closes when another tab is shown.
    private var findTab: (any EngineTab)?
    /// The back, forward and reload or stop buttons in the window's toolbar.
    let navigationToolbar = NavigationToolbar()
    /// What the navigation controls offer for the active tab; the toolbar and the menu items follow it.
    private(set) var navigationControls = NavigationControls.disabled
    /// The window's tabs as BowCore models them: order, active tab, and what each page last reported.
    private(set) var tabList = TabList()
    /// The engine tab behind each entry of `tabList`.
    private var engineTabs: [BrowserTabID: any EngineTab] = [:]
    /// The site icon of each tab, keyed by the address it was loaded from; nil while it loads or failed.
    private var favicons: [BrowserTabID: (url: URL, image: NSImage?)] = [:]
    /// What the New Tab button and New Tab menu item open.
    var newTabURL: URL
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?
    /// Called with every event of the window's tabs, after the window has handled it.
    var onTabEvent: ((any EngineTab, TabEvent) -> Void)?
    /// Asked before every main frame navigation of the window's tabs; nil allows every navigation.
    var navigationPolicy: ((any EngineTab, EngineNavigation) -> NavigationPolicy)?

    private let profile: any EngineProfile
    /// The window's permission prompts, anchored to `webView`, the page area to the right of the sidebar.
    let permissionPrompts: PermissionPrompts

    /// The window's open tabs, in sidebar order.
    var tabs: [any EngineTab] { tabList.tabs.compactMap { engineTabs[$0.id] } }

    /// The tab `webView` shows, read back from the view so it always matches the screen (the view refuses a tab
    /// that is closing).
    var selectedTab: (any EngineTab)? { tabs.first { webView.isShowing($0) } }

    /// Opens `url` in a new centered window on `profile`, or in `window` when given (e2e runs pass an off-screen
    /// one), which is not cascaded: the caller places it. New tabs open `newTabURL`, `url` when not given.
    /// Permission requests are answered from, and recorded in, `permissions`, the profile's store.
    init(
        url: URL,
        profile: any EngineProfile,
        permissions: SitePermissionStore,
        newTabURL: URL? = nil,
        window givenWindow: BrowserWindow? = nil
    ) {
        let window =
            givenWindow
            ?? BrowserWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: Self.styleMask,
                backing: .buffered,
                defer: false
            )
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        let webView = BowWebView(frame: NSRect(origin: .zero, size: contentSize))
        self.webView = webView
        sidebar = TabSidebarView(frame: .zero)
        self.profile = profile
        self.newTabURL = newTabURL ?? url
        permissionPrompts = PermissionPrompts(store: permissions, profile: profile, hostView: webView)
        window.title = "Bow"
        window.isReleasedWhenClosed = false
        window.contentView = Self.layout(sidebar: sidebar, webView: webView, findBar: findBar, size: contentSize)
        if givenWindow == nil { window.center() }
        super.init(window: window)
        if givenWindow != nil {
            // A window controller cascades its window to a new spot; the caller places a given window itself.
            shouldCascadeWindows = false
        }
        window.delegate = self
        navigationToolbar.install(in: window, target: self)
        sidebar.delegate = self
        findBar.onTextChange = { [weak self] _ in self?.runFind(forward: true) }
        findBar.onStep = { [weak self] forward in self?.runFind(forward: forward) }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
        openTab(url: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The window's content: the sidebar at a fixed width on the left, and the page area filling the rest, the web
    /// view with the hidden find bar over its top right corner.
    private static func layout(sidebar: TabSidebarView, webView: BowWebView, findBar: FindBar, size: NSSize)
        -> NSView
    {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(findBar)
        for view in [sidebar, content] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: TabSidebarView.width),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ])
        return root
    }

    // MARK: Tabs

    /// Opens `url` in a new tab of this window's profile, right after the active tab, selecting it unless
    /// `select` is false.
    @discardableResult
    func openTab(url: URL, select: Bool = true) -> any EngineTab {
        let engineTab = profile.createTab(url: url)
        engineTab.delegate = self
        var model = BrowserTab(url: url)
        model.apply(engineTab.state)
        if model.url == nil { model.url = url }
        engineTabs[model.id] = engineTab
        tabList.open(model, activate: select)
        showActiveTab()
        return engineTab
    }

    /// Shows `tab`, one of this window's tabs.
    func select(_ tab: any EngineTab) {
        guard let id = modelID(of: tab) else { return }
        tabList.select(id)
        showActiveTab()
    }

    /// Moves `tab`, one of this window's tabs, to `index` in the sidebar order (clamped to the list).
    func move(_ tab: any EngineTab, to index: Int) {
        guard let id = modelID(of: tab) else { return }
        tabList.move(id, to: index)
        sidebar.show(tabList)
    }

    /// Closes `tab`, one of this window's tabs, after its page's beforeunload handler runs. Returns true once it has
    /// closed, and false when the person chose to stay at the page's leave prompt, which keeps the tab and its
    /// page as they were. The window shows a neighbor when the shown tab closes, and closes with its last tab.
    /// A tab that is not in this window (another window's, or one already closed) is left alone, and the result
    /// is whether it is closed.
    @discardableResult
    func closeTab(_ tab: any EngineTab) async -> Bool {
        guard modelID(of: tab) != nil else { return tab.isClosed }
        return await tab.close()
    }

    /// The tab list entry of `tab`, one of this window's tabs.
    func modelID(of tab: any EngineTab) -> BrowserTabID? {
        engineTabs.first { $0.value === tab }?.key
    }

    /// Shows the tab list's active tab in the web view, and the list in the sidebar.
    private func showActiveTab() {
        if let id = tabList.activeID, let tab = engineTabs[id] {
            let closesFind = findTab.map { $0 !== tab } ?? false
            webView.show(tab)
            // After showing it, so the keyboard the find bar gives back goes to the page now shown.
            if closesFind { closeFindBar() }
        }
        // The prompt follows the tab on screen: another tab shows its own waiting request, or none.
        permissionPrompts.show(selectedTab)
        sidebar.show(tabList)
        updateTitle()
        updateNavigationControls()
    }

    // MARK: Menu commands

    /// File > New Tab (Cmd+T) and the sidebar's New Tab button.
    @objc func newTab(_ sender: Any?) {
        openTab(url: newTabURL)
    }

    /// File > Close Tab (Cmd+W): closes the active tab, running its page's beforeunload handler.
    @objc func closeActiveTab(_ sender: Any?) {
        guard let id = tabList.activeID, let tab = engineTabs[id] else { return }
        Task { await closeTab(tab) }
    }

    // MARK: Sidebar

    func sidebar(_ sidebar: TabSidebarView, select id: BrowserTabID) {
        guard engineTabs[id] != nil else { return }
        tabList.select(id)
        showActiveTab()
    }

    func sidebar(_ sidebar: TabSidebarView, close id: BrowserTabID) {
        guard let tab = engineTabs[id] else { return }
        Task { await closeTab(tab) }
    }

    func sidebar(_ sidebar: TabSidebarView, move id: BrowserTabID, to index: Int) {
        tabList.move(id, to: index)
        sidebar.show(tabList)
    }

    func sidebarNewTab(_ sidebar: TabSidebarView) {
        newTab(sidebar)
    }

    func sidebar(_ sidebar: TabSidebarView, faviconFor id: BrowserTabID) -> NSImage? {
        favicons[id]?.image
    }

    // MARK: Engine events

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .stateChanged(let state):
            if let id = modelID(of: tab) {
                tabList.update(id, from: state)
                updateFavicon(of: id, tab: tab, url: state.faviconURL)
                sidebar.show(tabList)
                if id == tabList.activeID {
                    updateTitle()
                    updateNavigationControls()
                }
            }
        case .findResult(let result):
            if tab === findTab { findBar.show(result) }
        case .didCommit:
            // A prompt belongs to the page that asked; a new page asks again if it needs to.
            permissionPrompts.dismissRequests(of: tab)
        case .closed:
            // A tab closes from this window, from quitting or from its page; the window follows its last tab.
            permissionPrompts.dismissRequests(of: tab)
            tabClosed(tab)
        default:
            break
        }
        onTabEvent?(tab, event)
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        navigationPolicy?(tab, navigation) ?? .allow
    }

    // MARK: Find in page

    /// Edit > Find (Cmd+F): shows the find bar over the shown tab with the keyboard in its field, searching again
    /// for the text it kept from last time.
    @objc func showFindBar(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        let wasShown = !findBar.isHidden
        findTab = tab
        findBar.isHidden = false
        findBar.focus()
        if !wasShown { runFind(forward: true) }
    }

    /// Edit > Find Next (Cmd+G), also Enter in the find bar.
    @objc func findNext(_ sender: Any?) {
        stepFind(forward: true)
    }

    /// Edit > Find Previous (Shift+Cmd+G), also Shift+Enter in the find bar.
    @objc func findPrevious(_ sender: Any?) {
        stepFind(forward: false)
    }

    private func stepFind(forward: Bool) {
        // A closed bar opens and searches again, which already makes a match active; stepping too would skip one.
        if findBar.isHidden {
            showFindBar(nil)
        } else {
            runFind(forward: forward)
        }
    }

    /// Searches the find bar's tab for the bar's text: a new search when the text changed, otherwise a step to the
    /// next or previous match. Empty text stops the search and clears the count.
    private func runFind(forward: Bool) {
        guard let findTab else { return }
        let text = findBar.text
        if text.isEmpty {
            findTab.stopFind()
            findBar.show(nil)
        } else {
            findTab.find(text, forward: forward, matchCase: false)
        }
    }

    /// Hides the find bar and stops its search, clearing the page's highlights. The bar keeps its text for next
    /// time, and the keyboard goes back to the page.
    func closeFindBar() {
        guard let tab = findTab else { return }
        findTab = nil
        tab.stopFind()
        findBar.show(nil)
        let hadKeyboard = findBar.field.currentEditor() != nil
        findBar.isHidden = true
        if hadKeyboard { webView.focusAttachedTab() }
    }

    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        guard tabs.contains(where: { $0 === tab }) else { return .dismiss }
        return await permissionPrompts.decide(request, for: tab)
    }

    private func tabClosed(_ tab: any EngineTab) {
        if tab === findTab { closeFindBar() }
        guard let id = modelID(of: tab) else { return }
        engineTabs[id] = nil
        favicons[id] = nil
        // The tab list picks the neighbor that becomes active when the active tab closes.
        tabList.close(id)
        if tabList.isEmpty {
            sidebar.show(tabList)
            updateNavigationControls()
            window?.close()
        } else {
            showActiveTab()
        }
    }

    /// Loads the site icon at `url` for tab `id` when the address changed, and drops it when the page has none.
    private func updateFavicon(of id: BrowserTabID, tab: any EngineTab, url: URL?) {
        guard let url else {
            favicons[id] = nil
            return
        }
        guard favicons[id]?.url != url else { return }
        favicons[id] = (url, nil)
        EngineFavicons.load(for: tab, from: url, maxPixelSize: Self.faviconPixelSize) { [weak self] image in
            guard let self, self.favicons[id]?.url == url else { return }
            self.favicons[id] = (url, image)
            self.sidebar.reloadTab(id)
        }
    }

    // MARK: Navigation controls

    /// Goes back in the selected tab's history (toolbar button, History > Back, Cmd+[).
    @objc func goBack(_ sender: Any?) {
        selectedTab?.goBack()
    }

    /// Goes forward in the selected tab's history (toolbar button, History > Forward, Cmd+]).
    @objc func goForward(_ sender: Any?) {
        selectedTab?.goForward()
    }

    /// Reloads the selected tab (toolbar button while idle, View > Reload Page, Cmd+R), also while it loads.
    @objc func reloadPage(_ sender: Any?) {
        selectedTab?.reload()
    }

    /// Stops the selected tab's load (toolbar button while loading, View > Stop, Cmd+.).
    @objc func stopLoading(_ sender: Any?) {
        selectedTab?.stop()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): navigationControls.canGoBack
        case #selector(goForward(_:)): navigationControls.canGoForward
        case #selector(reloadPage(_:)): navigationControls.canReload
        case #selector(stopLoading(_:)): navigationControls.canStop
        case #selector(closeActiveTab(_:)): tabList.activeID != nil
        default: true
        }
    }

    /// Reads the controls from the tab list's active tab and shows them in the toolbar.
    private func updateNavigationControls() {
        let activeTab = tabList.activeTab.flatMap { engineTabs[$0.id]?.isClosed == false ? $0 : nil }
        navigationControls = NavigationControls(activeTab: activeTab)
        navigationToolbar.show(navigationControls)
    }

    private func updateTitle() {
        let title = tabList.activeTab?.title ?? ""
        window?.title = title.isEmpty ? "Bow" : title
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if engineTabs.isEmpty { return true }
        // Close every tab, each running its page's unload handlers; the window closes once the last one has.
        // A page the person chooses to stay on keeps its tab and the window open. Each close request asks the
        // pages again, as quitting again does.
        for tab in tabs {
            Task { _ = await tab.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// A window whose close requests (close button, Shift+Cmd+W, Window > Close) wait for the page to close first.
/// AppKit's `performClose(_:)` plays the alert sound whenever `windowShouldClose(_:)` says no, which here only
/// means "the page is closing, the window follows", so this asks the delegate without the sound.
class BrowserWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}
