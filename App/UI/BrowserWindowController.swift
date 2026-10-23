import AppKit
import BowCore

/// A browser window: its tabs and the host view that shows the active one. The window runs on a BowCore
/// `SidebarStore`: its tabs are the Favorites of the active Space's profile, then the tabs of the store's active
/// Space (its pinned section, then its today section), so a Favorite loads in place and can be the active tab like
/// any other; opening, selecting, closing and moving a tab are store changes, which the store saves as they happen. The
/// window keeps one engine tab per sidebar tab that has loaded; a saved tab loads its page only once it is selected,
/// so on launch only the active tab loads. Every engine tab is created in the profile of the Space that holds it.
///
/// It reaches the engine only through the BowCore protocols, and is the delegate of each of its tabs.
///
/// Everything else a window does (the toolbar, find, permission prompts, the sidebar) is a `BrowserWindowFeature`
/// listed in `WindowFeatures.all`. The window creates them, puts them in its responder chain, and tells them when
/// the shown tab changes, what its tabs report, when a tab opens or closes, and when the store changes. Add a feature
/// there, never here.
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
    /// Pin the page area's other edges to the window's content.
    private let pageTrailingConstraint: NSLayoutConstraint
    private let pageTopConstraint: NSLayoutConstraint
    private let pageBottomConstraint: NSLayoutConstraint
    /// The window's features, in `WindowFeatures.all` order, which is also their order in the responder chain.
    private(set) var features: [any BrowserWindowFeature] = []
    /// The sidebar the window shows and changes: the source of truth for its tabs, their order and the active tab.
    let store: SidebarStore
    /// The engine profile behind a Space's profile ID, or nil when the engine has no such profile.
    private let profiles: (SidebarProfileID) -> (any EngineProfile)?
    /// What each sidebar tab the window knows last reported, under a runtime ID that lasts as long as the window.
    private var runtimeTabs: [SidebarItemID: BrowserTab] = [:]
    /// The sidebar tab behind each runtime ID, the reverse of `runtimeTabs`.
    private var itemIDs: [BrowserTabID: SidebarItemID] = [:]
    /// The engine tab of each sidebar tab that has loaded.
    private var engineTabs: [BrowserTabID: any EngineTab] = [:]
    /// The runtime ID of each engine tab, the reverse of `engineTabs`.
    private var modelIDs: [TabID: BrowserTabID] = [:]
    /// Tabs the person is closing (Close Tab, a row's close button, `closeTab(_:)`), which leave the sidebar once
    /// their page has closed. A tab that closes any other way (its window closing, quitting, its page closing
    /// itself) keeps its place in the sidebar with its saved page.
    private var closingByRequest: Set<BrowserTabID> = []
    /// The tabs the window asked to close to close itself, each under the request that asked, so a page that stays
    /// open withdraws only its own tab (a later close request asks it again under a new number).
    private var closingWithWindow: [BrowserTabID: Int] = [:]
    private var lastWindowCloseRequest = 0
    /// Pages whose sidebar item left the store (its Space deleted, archived, a Favorite removed), which the window is
    /// closing so no page runs without a row.
    private var closingOrphans: Set<BrowserTabID> = []
    /// Which closed pages closed themselves, told apart from pages the engine never created.
    private var selfClosedPages = SelfClosedPages()
    /// A pinned tab the person closed while it was the Space's only tab: it stays active but unloaded, also across a
    /// switch to another Space and back, and loads again only once the person selects it.
    private var keptUnloaded: SidebarItemID?
    /// Writes the sidebar a short while after the last page it recorded, so a page changing its title or address
    /// many times writes the file once. Window close and quit write what is left.
    private var pendingSave: Timer?
    static let recordSaveDelay: TimeInterval = 1
    /// The Space the features were last told is on screen.
    private var shownSpaceID: SidebarSpaceID?
    /// What the New Tab button and New Tab menu item open.
    var newTabURL: URL
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?
    /// Called when the window becomes the main window.
    var onBecomeMain: ((BrowserWindowController) -> Void)?
    /// Called with every event of the window's tabs, after the window has handled it.
    var onTabEvent: ((any EngineTab, TabEvent) -> Void)?
    /// Asked before every main frame navigation of the window's tabs; nil allows every navigation.
    var navigationPolicy: ((any EngineTab, EngineNavigation) -> NavigationPolicy)?

    /// The app's services (per-profile stores and the like), for features to look up.
    let appFeatures: AppFeatureSet

    /// The window's tabs as the sidebar lists them: the Favorites the active Space shows, then the active Space's tabs
    /// in sidebar order, with what each page last reported, and the active tab. Saved tabs that have not loaded show
    /// their saved address and title.
    var tabList: TabList {
        let tabs = listedTabIDs.compactMap { runtimeTabs[$0] }
        // With none active, the Space's first own tab stands in, never a Favorite, so an empty Space stays empty.
        let active =
            activeItemID.flatMap { runtimeTabs[$0]?.id } ?? activeSpaceTabIDs.first.flatMap { runtimeTabs[$0]?.id }
        return TabList(tabs: tabs, activeID: active) ?? TabList()
    }

    /// The window's loaded tabs in the active Space and its Favorites, in sidebar order.
    var tabs: [any EngineTab] { tabList.tabs.compactMap { engineTabs[$0.id] } }

    /// The tab `webView` shows, read back from the view so it always matches the screen (the view refuses a tab
    /// that is closing).
    var selectedTab: (any EngineTab)? { tabs.first { webView.isShowing($0) } }

    /// The Space on screen.
    var activeSpace: SidebarSpace? { store.graph.activeSpace }

    /// The engine profile of the Space on screen, which new tabs open in. Nil when the engine has no profile for the
    /// Space, in which case no tab opens.
    var activeProfile: (any EngineProfile)? { activeSpace.flatMap { profiles($0.profileID) } }

    /// True from the moment the window starts closing its tabs to close itself until it closes, or until every page
    /// that was asked chose to stay. A closing window opens no new tab, so links go to another window.
    var isClosing: Bool { !closingWithWindow.isEmpty }

    /// The engine profile `tab` was created in, through the window's profile resolver, so a feature reaches the
    /// tab's own profile (its permission store, for example) rather than the profile of the Space on screen.
    func engineProfile(of tab: any EngineTab) -> (any EngineProfile)? {
        profiles(SidebarStores.sidebarProfileID(of: tab.profileID))
    }

    /// The active Space's own tabs in sidebar order: its pinned section, then its today section.
    private var activeSpaceTabIDs: [SidebarItemID] {
        store.graph.activeSpaceID.map { store.graph.tabIDs(in: $0) } ?? []
    }

    /// Every tab the window lists: the Favorites of the active Space's profile, then the Space's own tabs.
    private var listedTabIDs: [SidebarItemID] {
        let graph = store.graph
        let favorites = graph.activeSpace.map { graph.favoriteIDs(for: $0.profileID) } ?? []
        return favorites + activeSpaceTabIDs
    }

    /// The store's active tab when the window lists it, else nil.
    private var activeItemID: SidebarItemID? {
        guard let id = store.graph.activeTabID, runtimeTabs[id] != nil else { return nil }
        return id
    }

    /// Opens a window on `store` showing its active Space, in a new centered window or in `window` when given (e2e
    /// runs pass an off-screen one), which is not cascaded: the caller places it. When `url` is given it opens in a
    /// new tab; otherwise only the saved active tab loads, and the other saved tabs load once they are selected.
    /// Each tab opens in the engine profile `profiles` gives for its Space. New tabs open `newTabURL`. Features find
    /// the app's services in `appFeatures`.
    init(
        store: SidebarStore,
        profiles: @escaping (SidebarProfileID) -> (any EngineProfile)?,
        url: URL?,
        newTabURL: URL,
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
        pageTrailingConstraint = pageArea.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
        pageTopConstraint = pageArea.topAnchor.constraint(equalTo: rootView.topAnchor)
        pageBottomConstraint = pageArea.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        self.store = store
        self.profiles = profiles
        self.appFeatures = appFeatures
        self.newTabURL = newTabURL
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
        installFeatures()
        if let url {
            openTab(url: url)
        } else {
            storeDidChange()
        }
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
            pageLeadingConstraint, pageTrailingConstraint, pageTopConstraint, pageBottomConstraint,
        ])
    }

    // MARK: Page container

    // The seam window chrome (a hidden toolbar, rounded page corners) changes the page's frame through, so chrome
    // features never edit the window core. Each defaults to today's look: no insets, square corners, a normal title
    // bar.

    /// Space between the page area and the window's content edges (the leading inset counts from the attached
    /// leading view, when there is one).
    var pageInsets = NSEdgeInsetsZero {
        didSet { applyPageInsets() }
    }

    /// The page area's corner radius, clipping the page; 0 keeps square corners.
    var pageCornerRadius: CGFloat = 0 {
        didSet {
            pageArea.wantsLayer = true
            pageArea.layer?.cornerRadius = pageCornerRadius
            pageArea.layer?.cornerCurve = .continuous
            pageArea.layer?.masksToBounds = pageCornerRadius > 0
        }
    }

    /// Whether the window's content runs under a transparent title bar (the full size content style), so chrome can
    /// draw up to the window's top edge; the page area then starts at `pageInsets.top` from that edge.
    var usesFullSizeContent: Bool {
        get { window?.styleMask.contains(.fullSizeContentView) ?? false }
        set {
            guard let window else { return }
            if newValue {
                window.styleMask.insert(.fullSizeContentView)
            } else {
                window.styleMask.remove(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = newValue
        }
    }

    private func applyPageInsets() {
        pageLeadingConstraint.constant = pageInsets.left
        pageTrailingConstraint.constant = -pageInsets.right
        pageTopConstraint.constant = pageInsets.top
        pageBottomConstraint.constant = -pageInsets.bottom
    }

    /// Places `view` along the window's leading edge at a fixed `width`, full height, with the page area to its
    /// right. A window has one leading view (the sidebar).
    func attachLeadingView(_ view: NSView, width: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(view)
        pageLeadingConstraint.isActive = false
        pageLeadingConstraint = pageArea.leadingAnchor.constraint(
            equalTo: view.trailingAnchor, constant: pageInsets.left)
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
    private func installFeatures() {
        features = WindowFeatures.all.map { $0.init(window: self) }
        // AppKit already put this controller right after its window.
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

    /// Opens `url` in a new tab in the active Space's today section, right after the active tab when that is a
    /// today tab and at the end otherwise, selecting it unless `select` is false. The tab opens in the active Space's
    /// profile; every way of opening a tab comes here or to `adoptTab`. Returns nil, opening nothing, when the Space's
    /// profile is missing or the store refuses the change.
    @discardableResult
    func openTab(url: URL, select: Bool = true) -> (any EngineTab)? {
        guard let space = store.graph.activeSpace else {
            Self.report("the window has no Space on screen, so the tab was not opened")
            return nil
        }
        guard
            let (item, profile) = insertTab(url: url, in: space, placement: .afterOpener, after: nil, select: select)
        else { return nil }
        let tab = load(item, url: url, in: profile)
        storeDidChange()
        return tab
    }

    /// Takes `tab`, an engine tab the engine already created (a popup the page opened as a tab, later a promoted
    /// Peek), as a new sidebar tab in the today section of the Space holding `opener` (the Space on screen when the
    /// opener is in none, a Favorite for example), selecting it unless `select` is false or that Space is not on
    /// screen. With `.afterOpener` it goes right after `opener` when that is a today tab (else after the Space's active
    /// today tab, else at the end); with `.topOfToday` at the top of today. The tab keeps its page (and
    /// `window.opener`). Pass `url` (a popup's `PopupRequest.targetURL`): the tab has reported no address yet, and the
    /// row saves `url` until the page reports its own. Returns false, taking nothing, when the window is closing, the
    /// tab is closed or already the window's, its profile is not that Space's, or the store refuses; the caller then
    /// closes it.
    @discardableResult
    func adoptTab(
        _ tab: any EngineTab,
        after opener: (any EngineTab)?,
        placement: PopupPlacement = .afterOpener,
        select: Bool = true,
        url: URL? = nil
    ) -> Bool {
        guard !tab.isClosed, modelID(of: tab) == nil else {
            Self.report("the tab is closed or already in the window, so it was not adopted")
            return false
        }
        let graph = store.graph
        let openerItem = opener.flatMap { modelID(of: $0) }.flatMap { itemIDs[$0] }
        let openerSpace = openerItem.flatMap { graph.spaceID(containing: $0) }.flatMap { graph.space($0) }
        guard let space = openerSpace ?? graph.activeSpace,
            SidebarStores.sidebarProfileID(of: tab.profileID) == space.profileID
        else {
            Self.report("the tab's profile is not its Space's, so it was not adopted")
            return false
        }
        let pageURL = url ?? tab.state.url
        guard
            let (item, _) = insertTab(
                url: pageURL ?? URL(string: "about:blank")!, in: space, placement: placement, after: openerItem,
                select: select)
        else { return false }
        attach(tab, to: item, url: pageURL)
        storeDidChange()
        return true
    }

    /// Inserts a sidebar tab on `url` into `space`'s today section at `placement` (`.afterOpener` places it after
    /// `anchor` when that is a today tab, else after the active today tab, else at the end). When `space` is on screen
    /// the tab becomes active if `select` is true or the Space has no active tab; a Space not on screen keeps its
    /// selection. Returns the new item and the profile its page belongs in, or nil, inserting nothing, when the window
    /// is closing, the Space's profile is missing or the store refuses.
    private func insertTab(
        url: URL,
        in space: SidebarSpace,
        placement: PopupPlacement,
        after anchor: SidebarItemID?,
        select: Bool
    ) -> (SidebarItemID, any EngineProfile)? {
        let graph = store.graph
        guard !isClosing else {
            Self.report("the window is closing, so the tab was not opened")
            return nil
        }
        guard let profile = profiles(space.profileID) else {
            Self.report("the Space has no profile, so the tab was not opened")
            return nil
        }
        let onScreen = space.id == graph.activeSpaceID
        let today = space.unpinnedContainerID
        let index: Int?
        switch placement {
        case .topOfToday:
            index = 0
        case .afterOpener:
            let todayIndex = { (id: SidebarItemID) -> Int? in
                guard graph[id]?.parentID == today else { return nil }
                return graph[today]?.childrenIDs.firstIndex(of: id).map { $0 + 1 }
            }
            index = anchor.flatMap(todayIndex) ?? (onScreen ? graph.activeTabID.flatMap(todayIndex) : nil)
        }
        let item = SidebarItem.tab(url: url.absoluteString)
        let inserted = change { store in
            try store.transaction {
                try store.mutate(.insert(item, parent: today, index: index))
                if onScreen, select || graph.activeTabID == nil { try store.mutate(.setActiveTab(item.id)) }
            }
        }
        return inserted ? (item.id, profile) : nil
    }

    /// Shows `tab`, one of this window's tabs.
    func select(_ tab: any EngineTab) {
        guard let id = modelID(of: tab) else { return }
        select(id)
    }

    /// Makes tab `id` active and shows it, loading its saved page first if it has not loaded. A tab that cannot be
    /// shown (it is closing, or its page could not load) leaves the active tab as it was, so the sidebar and the page
    /// area always agree.
    func select(_ id: BrowserTabID) {
        guard let item = itemIDs[id] else { return }
        let previous = store.graph.activeTabID
        let previousKept = keptUnloaded
        if keptUnloaded == item { keptUnloaded = nil }
        change { try $0.selectTab(item) }
        storeDidChange()
        let shown = engineTabs[id].map { webView.isShowing($0) } ?? false
        if !shown, let previous, previous != item, store.graph[previous] != nil {
            change { try $0.selectTab(previous) }
            // A pinned tab kept unloaded stays so when the selection returns to it.
            if previousKept == previous { keptUnloaded = previous }
            storeDidChange(loadActive: false)
        }
    }

    /// Runs `body` on the window's store for a feature (a sidebar drag that moves, pins or unpins a tab), then brings
    /// the window up to date and tells the features, as the window's own changes do. A refusal is reported and changes
    /// nothing. Returns whether the change went through.
    @discardableResult
    func changeSidebar(_ body: (SidebarStore) throws -> Void) -> Bool {
        let changed = change(body)
        storeDidChange()
        return changed
    }

    /// Closes `tab`, one of this window's tabs, after its page's beforeunload handler runs. Returns true once it has
    /// closed, and false when the person chose to stay at the page's leave prompt, which keeps the tab and its
    /// page as they were. The closed tab leaves the sidebar (a pinned tab only unloads and stays); the window shows a
    /// neighbor when the shown tab closes, and closes with its last tab. A tab that is not in this window (another
    /// window's, or one already closed) is left alone, and the result is whether it is closed.
    @discardableResult
    func closeTab(_ tab: any EngineTab) async -> Bool {
        guard let id = modelID(of: tab) else { return tab.isClosed }
        closingByRequest.insert(id)
        let closed = await tab.close()
        if !closed { closingByRequest.remove(id) }
        return closed
    }

    /// Closes tab `id` the way the person does: a loaded tab as `closeTab(_:)` does, a saved tab that has not loaded
    /// at once (it has no page to ask). Returns whether it closed.
    @discardableResult
    func closeTab(id: BrowserTabID) async -> Bool {
        if let tab = engineTabs[id] { return await closeTab(tab) }
        guard let item = itemIDs[id] else { return false }
        removeFromSidebar(item)
        updateAfterClose(closedWithWindow: false)
        return true
    }

    /// The runtime ID of `tab`, one of this window's tabs.
    func modelID(of tab: any EngineTab) -> BrowserTabID? {
        modelIDs[tab.tabID].flatMap { engineTabs[$0] === tab ? $0 : nil }
    }

    /// The engine tab behind runtime ID `id`, nil while its saved page has not loaded.
    func engineTab(for id: BrowserTabID) -> (any EngineTab)? {
        engineTabs[id]
    }

    /// The sidebar item behind runtime ID `id`.
    func sidebarItemID(for id: BrowserTabID) -> SidebarItemID? {
        itemIDs[id]
    }

    /// Runs `body` on the store and reports a refusal. Returns whether the change went through (a failed write keeps
    /// it, unsaved, for the store to write with the next change or on quit). Callers follow with `storeDidChange()`.
    @discardableResult
    private func change(_ body: (SidebarStore) throws -> Void) -> Bool {
        do {
            try body(store)
            return true
        } catch SidebarStoreError.saveFailed(let reason) {
            Self.report("saving the sidebar failed: \(reason)")
            return true
        } catch {
            Self.report("the sidebar refused a change: \(error)")
            return false
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("bow: \(message)\n".utf8))
    }

    /// Creates the engine tab of sidebar tab `item` on `url` in `profile`, the profile of the Space that holds it.
    @discardableResult
    private func load(_ item: SidebarItemID, url: URL, in profile: any EngineProfile) -> any EngineTab {
        let engineTab = profile.createTab(url: url)
        attach(engineTab, to: item, url: url)
        return engineTab
    }

    /// Makes `engineTab` the page of sidebar tab `item`: the window becomes its delegate, and the features hear of it.
    private func attach(_ engineTab: any EngineTab, to item: SidebarItemID, url: URL?) {
        var model = runtimeTab(for: item, url: url)
        engineTab.delegate = self
        model.apply(engineTab.state)
        if model.url == nil { model.url = url }
        runtimeTabs[item] = model
        engineTabs[model.id] = engineTab
        modelIDs[engineTab.tabID] = model.id
        for feature in features { feature.tabOpened(engineTab, item: item) }
    }

    /// The runtime tab of `item`, made from its saved page (or `url`) the first time.
    @discardableResult
    private func runtimeTab(for item: SidebarItemID, url: URL? = nil) -> BrowserTab {
        if let tab = runtimeTabs[item] { return tab }
        let saved = store.graph[item]?.tab
        let tab = BrowserTab(url: url ?? saved?.savedPageURL, title: saved?.savedTitle ?? "")
        runtimeTabs[item] = tab
        itemIDs[tab.id] = item
        return tab
    }

    /// Brings the window up to date with the store: the listed tabs, the active tab shown (loading its saved page first
    /// unless `loadActive` is false), then tells the features.
    private func storeDidChange(loadActive: Bool = true) {
        let ids = listedTabIDs
        for id in ids { runtimeTab(for: id) }
        // Tabs that left the store or the Space on screen and have no page are forgotten.
        let listed = Set(ids)
        for (item, tab) in runtimeTabs where !listed.contains(item) && engineTabs[tab.id] == nil {
            runtimeTabs[item] = nil
            itemIDs[tab.id] = nil
        }
        closeOrphans()
        if let kept = keptUnloaded {
            let graph = store.graph
            let onScreen =
                graph.spaceID(containing: kept) == graph.activeSpaceID
                || graph.activeSpaceID.map { graph.isInFavorites(kept, shownBy: $0) } == true
            let selectedOther = onScreen && graph.activeTabID != kept
            if graph[kept] == nil || selectedOther { keptUnloaded = nil }
        }
        let loadActive = loadActive && !isClosing
        // A Space with tabs always has one active (a saved sidebar may name none, or a tab that is gone). A Favorite is
        // never chosen for it, so an empty Space shows its empty state rather than loading a Favorite.
        if loadActive, activeItemID == nil, let first = activeSpaceTabIDs.first {
            change { try $0.apply([.setActiveTab(first)]) }
        }
        if loadActive, let item = activeItemID, item != keptUnloaded, let runtime = runtimeTabs[item],
            engineTabs[runtime.id] == nil
        {
            loadSaved(item)
        }
        if let space = activeSpace, space.id != shownSpaceID {
            shownSpaceID = space.id
            for feature in features { feature.activeSpaceChanged(space) }
        }
        for feature in features { feature.storeChanged(store.graph) }
        showActiveTab()
    }

    /// Loads the saved page of `item` in the profile of the Space that holds it (or of the Favorites it is in).
    private func loadSaved(_ item: SidebarItemID) {
        let graph = store.graph
        let profileID =
            graph.spaceID(containing: item).flatMap { graph.space($0)?.profileID }
            ?? graph.favoritesProfileID(containing: item)
        guard let profileID, let profile = profiles(profileID) else {
            Self.report("tab \(item) has no profile, so it was not loaded")
            return
        }
        // A pinned tab returns to its saved address; any other tab to the page it last recorded.
        let url = graph.pinnedURL(of: item) ?? graph[item]?.tab?.savedPageURL ?? newTabURL
        load(item, url: url, in: profile)
    }

    /// Shows the active tab in the web view, then tells the features.
    private func showActiveTab() {
        if let item = activeItemID, let id = runtimeTabs[item]?.id, let tab = engineTabs[id] {
            webView.show(tab)
        } else {
            // No page for the active tab (an empty Space, a pinned tab kept unloaded): the page area shows none,
            // never the page of a tab the sidebar no longer marks active.
            webView.detach()
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

    /// File > New Tab (Cmd+T) and the sidebar's New Tab button: the first feature that handles it does, else a new
    /// tab opens on `newTabURL`.
    @objc func newTab(_ sender: Any?) {
        for feature in features where feature.handleNewTab(sender) { return }
        openTab(url: newTabURL)
    }

    /// File > Close Tab (Cmd+W): closes the active tab, running its page's beforeunload handler.
    @objc func closeActiveTab(_ sender: Any?) {
        guard let id = tabList.activeID else { return }
        Task { await closeTab(id: id) }
    }

    /// Validates the window's own commands; each feature validates its own.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(closeActiveTab(_:)) ? tabList.activeID != nil : true
    }

    // MARK: Engine events

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        selfClosedPages.record(event, of: tab.tabID)
        if case .stateChanged(let state) = event, let id = modelID(of: tab), let item = itemIDs[id] {
            runtimeTabs[item]?.apply(state)
            recordPage(of: item, state: state)
            if item == activeItemID { updateTitle() }
        }
        for feature in features { feature.tab(tab, didReceive: event) }
        // A tab closes from this window, from quitting or from its page; the window follows its last tab.
        if event == .closed { tabClosed(tab) }
        onTabEvent?(tab, event)
    }

    /// Records the page a today tab shows as its saved page, so a relaunch brings it back on that page. Pinned tabs
    /// and Favorites keep the address they were saved with. It records once a load has settled, not each step of it.
    private func recordPage(of item: SidebarItemID, state: EngineTabState) {
        let graph = store.graph
        guard !state.isLoading, let url = state.url, let saved = graph[item]?.tab, !graph.isPinned(item),
            !graph.isInFavorites(item),
            saved.savedURL != url.absoluteString || saved.savedTitle != state.title
        else { return }
        // Committed now and written shortly after, so a title that changes many times writes the file once.
        let record = SidebarMutation.setSavedPage(item, url: url.absoluteString, title: state.title)
        guard change({ try $0.apply([record], saving: false) }) else { return }
        guard pendingSave == nil else { return }
        // In the common modes, so a menu open or a drag in progress does not hold the write back.
        let timer = Timer(timeInterval: Self.recordSaveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveRecordedPages() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingSave = timer
    }

    /// Writes the pages recorded since the last write, if no other change wrote them already.
    private func saveRecordedPages() {
        pendingSave?.invalidate()
        pendingSave = nil
        change { try $0.save() }
    }

    /// Closes the pages whose sidebar item left the store, each running its beforeunload handler once: a page whose
    /// person chooses to stay keeps running, unlisted, and is not asked again by later changes (closing the window
    /// asks it again, as it asks every page).
    private func closeOrphans() {
        // A page asked before whose row came back is asked again should its row leave again.
        closingOrphans = closingOrphans.filter { id in itemIDs[id].map { store.graph[$0] == nil } ?? true }
        for (item, runtime) in runtimeTabs where store.graph[item] == nil {
            guard let tab = engineTabs[runtime.id], closingOrphans.insert(runtime.id).inserted else { continue }
            Task { _ = await tab.close() }
        }
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        navigationPolicy?(tab, navigation) ?? .allow
    }

    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        // Any loaded tab of the window may ask, also one in a Space not on screen; it waits for its prompt there.
        guard modelID(of: tab) != nil else { return .dismiss }
        for feature in features {
            if let decision = await feature.decidePermission(request, for: tab) { return decision }
        }
        return .dismiss
    }

    // Each hook below goes to the features only for the window's own tabs; the first feature that answers decides,
    // and with none (or for a tab that is not the window's) the window keeps the engine contract's default.

    func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision {
        // A closing window takes no new tab, so its pages' popups keep the engine's own window.
        guard modelID(of: tab) != nil, !isClosing else { return .window }
        return features.lazy.compactMap { $0.decidePopup(request, from: tab) }.first ?? .window
    }

    func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest) {
        if modelID(of: tab) != nil, !isClosing,
            features.contains(where: { $0.didOpenPopup(newTab, from: tab, request: request) })
        {
            return
        }
        // Nobody took the tab: close it, so a page never lives on unseen.
        Task { _ = await newTab.close() }
    }

    func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool {
        guard modelID(of: tab) != nil else { return false }
        return features.contains { $0.handleKeyBeforePage(event, in: tab) }
    }

    func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials? {
        guard modelID(of: tab) != nil else { return nil }
        for feature in features {
            if let credentials = await feature.answer(challenge, for: tab) { return credentials }
        }
        return nil
    }

    func tab(_ tab: any EngineTab, decideCertificateError error: CertificateError) async -> CertificateErrorDecision {
        guard modelID(of: tab) != nil else { return .cancel }
        for feature in features {
            if let decision = await feature.decideCertificateError(error, for: tab) { return decision }
        }
        return .cancel
    }

    private func tabClosed(_ tab: any EngineTab) {
        for feature in features { feature.tabDidClose(tab) }
        let closedItself = selfClosedPages.closedItself(tab)
        guard let id = modelID(of: tab) else { return }
        engineTabs[id] = nil
        modelIDs[tab.tabID] = nil
        let closedWithWindow = closingWithWindow.removeValue(forKey: id) != nil
        closingOrphans.remove(id)
        let requested = closingByRequest.remove(id) != nil
        // A page that closed itself goes as a close would: a today tab leaves, a pinned one unloads and stays. A
        // page the engine could not create closes for the same reason but never had a page, so it keeps its row.
        let closedByPage = !closedWithWindow && !isClosing && closedItself
        guard requested || closedByPage, let item = itemIDs[id], store.graph[item] != nil else {
            // Closed with its window, by quitting, never created, or for a reason the engine did not give: the tab
            // keeps its place in the sidebar, unloaded.
            // A closing window follows its last open tab. Otherwise nothing else loads, since quitting must leave
            // the sidebar's active tab as it was; selecting a row loads it.
            if (closedWithWindow || isClosing) && engineTabs.isEmpty {
                for feature in features { feature.selectedTabChanged(nil) }
                window?.close()
            } else if closedWithWindow && !isClosing {
                // A window close that a page stayed through has ended: show the page the person stayed on.
                showAfterStayedClose()
            } else {
                // Quitting and a tab closed for no known reason load nothing, so quitting leaves the active tab as it
                // was.
                storeDidChange(loadActive: false)
            }
            return
        }
        removeFromSidebar(item)
        updateAfterClose(closedWithWindow: closedWithWindow)
    }

    /// Brings the window up to date after the person closed a tab. A closing window loads nothing and closes once its
    /// last page has; otherwise the new active tab shows, and a Space left with no tabs keeps the window open on its
    /// empty state.
    private func updateAfterClose(closedWithWindow: Bool) {
        if closedWithWindow || isClosing {
            if engineTabs.isEmpty {
                for feature in features { feature.selectedTabChanged(nil) }
                window?.close()
            } else {
                storeDidChange(loadActive: false)
            }
        } else {
            storeDidChange()
        }
    }

    /// Takes a tab the person closed out of the sidebar (a pinned tab or a Favorite only unloads and stays). When it
    /// was the active tab, the tab after it becomes active, or the one before it when it was last (for a Favorite, the
    /// Space's first tab); a pinned tab or Favorite left with no tab of the Space to show stays active, unloaded,
    /// until the person selects it.
    private func removeFromSidebar(_ item: SidebarItemID) {
        let graph = store.graph
        guard graph[item] != nil else { return }
        let ids = activeSpaceTabIDs
        let removes = graph.closeOutcome(for: item) == .removeFromSidebar
        var next = graph.activeTabID
        var keeps = false
        let favoriteShown = graph.activeSpaceID.map { graph.isInFavorites(item, shownBy: $0) } == true
        if graph.activeTabID == item, let position = ids.firstIndex(of: item) ?? (favoriteShown ? 0 : nil) {
            let rest = ids.filter { $0 != item }
            if !rest.isEmpty {
                next = rest[min(position, rest.count - 1)]
            } else if removes {
                next = nil
            } else {
                keeps = true
            }
        }
        let changed = change { store in
            try store.transaction {
                if removes { try store.mutate(.delete(item)) }
                try store.mutate(.setActiveTab(next))
            }
        }
        guard changed else { return }
        if keeps { keptUnloaded = item }
        if removes, let runtime = runtimeTabs.removeValue(forKey: item) { itemIDs[runtime.id] = nil }
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if engineTabs.isEmpty { return true }
        // Close every open tab, each running its page's unload handlers; the window closes once the last one has, and
        // the tabs keep their place in the sidebar. A page the person chooses to stay on keeps its tab and the window
        // open. Each close request asks the pages again, as quitting again does.
        lastWindowCloseRequest += 1
        let request = lastWindowCloseRequest
        for (id, tab) in engineTabs {
            closingWithWindow[id] = request
            Task {
                guard !(await tab.close()), self.closingWithWindow[id] == request else { return }
                self.closingWithWindow[id] = nil
                // Once every page asked has answered and one stayed, the window stays open on a page it stayed on.
                if !self.isClosing { self.showAfterStayedClose() }
            }
        }
        return false
    }

    /// Shows the window again once a close it was asked for has ended with a page staying: the active tab when its
    /// page is still open, else a listed page that stayed (one of the Space on screen first, else one of another
    /// Space, which comes on screen), rather than loading the closed active tab again. The active tab loads again only
    /// when no listed page stayed (an orphan page that stayed has no row to show).
    private func showAfterStayedClose() {
        if activeItemID.map(isLoaded) != true {
            let shown = listedTabIDs
            let listed = runtimeTabs.keys.filter { store.graph[$0] != nil && !shown.contains($0) }
            if let stayed = shown.first(where: isLoaded) ?? listed.first(where: isLoaded) {
                change { try $0.selectTab(stayed) }
            }
        }
        storeDidChange()
    }

    /// Whether sidebar tab `item` has an open page in this window.
    private func isLoaded(_ item: SidebarItemID) -> Bool {
        runtimeTabs[item].map { engineTabs[$0.id] != nil } ?? false
    }

    func windowDidBecomeMain(_ notification: Notification) {
        onBecomeMain?(self)
    }

    func windowWillClose(_ notification: Notification) {
        if pendingSave != nil { saveRecordedPages() }
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
