import AppKit
import BowCore

/// The sidebar along the window's leading edge (`SidebarView`): the Favorites area, the pinned tabs, a divider and
/// today's tabs of the Space on screen, each tab with its site icon. A click shows a tab, its close button closes it,
/// a drag moves it within or across pinned and today (pinning or unpinning it), and the New Tab button opens a tab
/// in today.
@MainActor
final class SidebarFeature: NSResponder, BrowserWindowFeature, SidebarViewDelegate {
    /// The size, in pixels, site icons are loaded at (16 points on a Retina screen).
    private static let faviconPixelSize = 32

    private unowned let window: BrowserWindowController
    let sidebar = SidebarView(frame: .zero)
    /// The site icon each tab shows and the address it came from.
    private var favicons: [BrowserTabID: (url: URL, image: NSImage)] = [:]
    /// The icon address each tab's page reported last, nil while it reports none.
    private var faviconReported: [BrowserTabID: URL] = [:]
    /// The runtime ID of each tab of the Space on screen, as last shown.
    private var runtimeIDs: [SidebarItemID: BrowserTabID] = [:]

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        window.attachLeadingView(sidebar, width: SidebarView.width)
        sidebar.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Also called after every store change (the window shows its active tab once it has updated), so the sidebar
    /// follows the store from here without a second refresh in `storeChanged(_:)`.
    func selectedTabChanged(_ tab: (any EngineTab)?) {
        refresh()
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        guard case .stateChanged(let state) = event, let id = window.modelID(of: tab) else { return }
        updateFavicon(of: id, tab: tab, url: state.faviconURL)
        refresh()
    }

    func tabDidClose(_ tab: any EngineTab) {
        guard let id = window.modelID(of: tab) else { return }
        favicons[id] = nil
        faviconReported[id] = nil
    }

    /// Shows the window's sidebar with what each tab of the Space on screen last reported.
    private func refresh() {
        let list = window.tabList
        var tabs: [SidebarItemID: BrowserTab] = [:]
        runtimeIDs = [:]
        for tab in list.tabs {
            guard let item = window.sidebarItemID(for: tab.id) else { continue }
            tabs[item] = tab
            runtimeIDs[item] = tab.id
        }
        let active = list.activeID.flatMap { window.sidebarItemID(for: $0) }
        sidebar.show(SidebarContent(graph: window.store.graph, tabs: tabs, activeItem: active))
    }

    /// Moves tab `id` to `index` in the window's tab list, as dropping its row there does: to the place of the tab
    /// that is at `index` once `id` has left its own (in that tab's section or folder, so it pins or unpins when that
    /// is the other zone), or to the end of today past the last tab. Returns whether it moved.
    @discardableResult
    func dropTab(_ id: BrowserTabID, atTabIndex index: Int) -> Bool {
        let graph = window.store.graph
        guard let item = window.sidebarItemID(for: id), let space = graph.activeSpace else { return false }
        let others = graph.tabIDs(in: space.id).filter { $0 != item }
        if others.indices.contains(index), let parent = graph[others[index]]?.parentID,
            let position = graph[parent]?.childrenIDs.firstIndex(of: others[index])
        {
            return sidebar.drop(item, into: parent, at: position)
        }
        let today = space.unpinnedContainerID
        return sidebar.drop(item, into: today, at: graph[today]?.childrenIDs.count ?? 0)
    }

    // MARK: SidebarViewDelegate

    var graph: SidebarGraph { window.store.graph }

    func select(_ item: SidebarItemID) {
        guard let id = runtimeIDs[item] else { return }
        window.select(id)
    }

    func close(_ item: SidebarItemID) {
        guard let id = runtimeIDs[item] else { return }
        // Held strongly, as a close can free the window before the task runs. A saved tab that has not loaded closes too.
        let window = window
        Task { await window.closeTab(id: id) }
    }

    @discardableResult
    func changeSidebar(_ body: (SidebarStore) throws -> Void) -> Bool {
        window.changeSidebar(body)
    }

    func livePage(of item: SidebarItemID) -> (url: URL, title: String)? {
        guard let id = runtimeIDs[item], let tab = window.engineTab(for: id), !tab.isClosed,
            let url = tab.state.url
        else { return nil }
        return (url, tab.state.title)
    }

    func sidebarNewTab() {
        window.newTab(sidebar)
    }

    func favicon(for item: SidebarItemID) -> NSImage? {
        runtimeIDs[item].flatMap { favicons[$0]?.image }
    }

    /// Loads the site icon at `url` for tab `id` each time the page reports a new icon address. The icon shown stays
    /// while a navigation has no address yet, so rows do not flicker; it goes once a new address fails to load.
    /// An address that failed is tried again when the page reports it anew.
    private func updateFavicon(of id: BrowserTabID, tab: any EngineTab, url: URL?) {
        guard faviconReported[id] != url else { return }
        faviconReported[id] = url
        guard let url, favicons[id]?.url != url else { return }
        EngineFavicons.load(for: tab, from: url, maxPixelSize: Self.faviconPixelSize) { [weak self] image in
            guard let self, self.faviconReported[id] == url else { return }
            self.favicons[id] = image.map { (url, $0) }
            if let item = self.window.sidebarItemID(for: id) { self.sidebar.reloadItem(item) }
        }
    }
}
