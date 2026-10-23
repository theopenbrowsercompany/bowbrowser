import AppKit
import BowCore

/// A browser window: its tabs and the host view that shows the active one. The order of the tabs and which one is
/// active live in a BowCore `TabList`; the window keeps one engine tab per entry. It reaches the engine only through
/// the BowCore protocols, and is the delegate of each of its tabs.
///
/// Everything else a window does (the toolbar, find, permission prompts, the sidebar) is a `BrowserWindowFeature`
/// listed in `WindowFeatures.all`. The window creates them, puts them in its responder chain, and tells them when
/// the shown tab changes, what its tabs report and when a tab closes. Add a feature there, never here.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, EngineTabDelegate {
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    /// Shows the selected tab. Switching tabs shows another tab here; pages are never reloaded by a switch.
    let webView: BowWebView
    /// The page area: the web view, with room for features to float views over it.
    let pageArea: NSView
    /// The window's content view, holding the page area and the view attached along its leading edge.
    private let rootView: NSView
    /// Pins the page area's leading edge: to the window's, or to the trailing edge of the attached leading view.
    private var pageLeadingConstraint: NSLayoutConstraint
    /// The window's features, in `WindowFeatures.all` order, which is also their order in the responder chain.
    private(set) var features: [any BrowserWindowFeature] = []
    /// The window's tabs as BowCore models them: order, active tab, and what each page last reported.
    private(set) var tabList = TabList()
    /// The engine tab behind each entry of `tabList`.
    private var engineTabs: [BrowserTabID: any EngineTab] = [:]
    /// The tab list entry of each engine tab, the reverse of `engineTabs`.
    private var modelIDs: [TabID: BrowserTabID] = [:]
    /// What the New Tab button and New Tab menu item open.
    var newTabURL: URL
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?
    /// Called with every event of the window's tabs, after the window has handled it.
    var onTabEvent: ((any EngineTab, TabEvent) -> Void)?
    /// Asked before every main frame navigation of the window's tabs; nil allows every navigation.
    var navigationPolicy: ((any EngineTab, EngineNavigation) -> NavigationPolicy)?

    let profile: any EngineProfile
    /// The app's services (per-profile stores and the like), for features to look up.
    let appFeatures: AppFeatureSet

    /// The window's open tabs, in tab list order.
    var tabs: [any EngineTab] { tabList.tabs.compactMap { engineTabs[$0.id] } }

    /// The tab `webView` shows, read back from the view so it always matches the screen (the view refuses a tab
    /// that is closing).
    var selectedTab: (any EngineTab)? { tabs.first { webView.isShowing($0) } }

    /// Opens `url` in a new centered window on `profile`, or in `window` when given (e2e runs pass an off-screen
    /// one), which is not cascaded: the caller places it. New tabs open `url` too until `newTabURL` is changed.
    /// Features find the app's services in `appFeatures`.
    init(
        url: URL,
        profile: any EngineProfile,
        appFeatures: AppFeatureSet,
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
        webView = BowWebView(frame: NSRect(origin: .zero, size: contentSize))
        rootView = NSView(frame: NSRect(origin: .zero, size: contentSize))
        pageArea = NSView(frame: NSRect(origin: .zero, size: contentSize))
        pageLeadingConstraint = pageArea.leadingAnchor.constraint(equalTo: rootView.leadingAnchor)
        self.profile = profile
        self.appFeatures = appFeatures
        self.newTabURL = url
        window.title = "Bow"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        layOut()
        window.contentView = rootView
        if givenWindow == nil {
            window.center()
        } else {
            // A window controller cascades its window to a new spot; the caller places a given window itself.
            shouldCascadeWindows = false
        }
        window.delegate = self
        installFeatures(in: window)
        openTab(url: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The window's content: the page area filling it, the web view filling the page area.
    private func layOut() {
        webView.frame = pageArea.bounds
        webView.autoresizingMask = [.width, .height]
        pageArea.addSubview(webView)
        pageArea.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(pageArea)
        NSLayoutConstraint.activate([
            pageLeadingConstraint,
            pageArea.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            pageArea.topAnchor.constraint(equalTo: rootView.topAnchor),
            pageArea.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
    }

    /// Places `view` along the window's leading edge at a fixed `width`, full height, with the page area to its
    /// right. A window has one leading view (the sidebar).
    func attachLeadingView(_ view: NSView, width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(view)
        pageLeadingConstraint.isActive = false
        pageLeadingConstraint = pageArea.leadingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            view.topAnchor.constraint(equalTo: rootView.topAnchor),
            view.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
            pageLeadingConstraint,
        ])
    }

    // MARK: Features

    /// Creates the window's features and puts them in the responder chain right after this controller: window,
    /// controller, the features in list order, then whatever followed the controller.
    private func installFeatures(in window: NSWindow) {
        features = WindowFeatures.all.map { $0.init(window: self) }
        if window.nextResponder !== self { window.nextResponder = self }
        let next = nextResponder
        var last: NSResponder = self
        for feature in features {
            last.nextResponder = feature
            last = feature
        }
        last.nextResponder = next
    }

    /// The window's feature of type `type`.
    func feature<Feature: BrowserWindowFeature>(_ type: Feature.Type) -> Feature? {
        features.lazy.compactMap { $0 as? Feature }.first
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
        modelIDs[engineTab.tabID] = model.id
        tabList.open(model, activate: select)
        showActiveTab()
        return engineTab
    }

    /// Shows `tab`, one of this window's tabs.
    func select(_ tab: any EngineTab) {
        guard let id = modelID(of: tab) else { return }
        select(id)
    }

    /// Makes tab `id` active and shows it. A tab that is closing cannot be shown, and the active tab stays.
    func select(_ id: BrowserTabID) {
        guard let tab = engineTabs[id] else { return }
        let previous = tabList.activeID
        tabList.select(id)
        showActiveTab()
        if !webView.isShowing(tab), let previous, previous != id {
            tabList.select(previous)
            showActiveTab()
        }
    }

    /// Moves tab `id` to `index` in the tab list.
    func reorderTab(_ id: BrowserTabID, to index: Int) {
        tabList.move(id, to: index)
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
        modelIDs[tab.tabID].flatMap { engineTabs[$0] === tab ? $0 : nil }
    }

    /// The engine tab behind tab list entry `id`.
    func engineTab(for id: BrowserTabID) -> (any EngineTab)? {
        engineTabs[id]
    }

    /// Shows the tab list's active tab in the web view, then tells the features.
    private func showActiveTab() {
        if let id = tabList.activeID, let tab = engineTabs[id] {
            webView.show(tab)
        }
        updateTitle()
        let shown = selectedTab
        for feature in features { feature.selectedTabChanged(shown) }
    }

    private func updateTitle() {
        let title = tabList.activeTab?.title ?? ""
        window?.title = title.isEmpty ? "Bow" : title
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

    /// Validates the window's own commands; each feature validates its own.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(closeActiveTab(_:)) ? tabList.activeID != nil : true
    }

    // MARK: Engine events

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        if case .stateChanged(let state) = event, let id = modelID(of: tab) {
            tabList.update(id, from: state)
            if id == tabList.activeID { updateTitle() }
        }
        for feature in features { feature.tab(tab, didReceive: event) }
        // A tab closes from this window, from quitting or from its page; the window follows its last tab.
        if event == .closed { tabClosed(tab) }
        onTabEvent?(tab, event)
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        navigationPolicy?(tab, navigation) ?? .allow
    }

    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        guard tabs.contains(where: { $0 === tab }) else { return .dismiss }
        for feature in features {
            if let decision = await feature.decidePermission(request, for: tab) { return decision }
        }
        return .dismiss
    }

    private func tabClosed(_ tab: any EngineTab) {
        for feature in features { feature.tabDidClose(tab) }
        guard let id = modelID(of: tab) else { return }
        engineTabs[id] = nil
        modelIDs[tab.tabID] = nil
        // The tab list picks the neighbor that becomes active when the active tab closes.
        tabList.close(id)
        if tabList.isEmpty {
            for feature in features { feature.selectedTabChanged(nil) }
            window?.close()
        } else {
            showActiveTab()
        }
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

/// A window whose close requests (close button, File > Close Window, Shift+Cmd+W) wait for the page to close first.
/// AppKit's `performClose(_:)` plays the alert sound whenever `windowShouldClose(_:)` says no, which here only
/// means "the page is closing, the window follows", so this asks the delegate without the sound.
class BrowserWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}
