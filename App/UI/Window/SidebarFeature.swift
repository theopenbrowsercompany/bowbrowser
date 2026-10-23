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
    /// Tabs whose page the engine unloaded, between that event and the window letting go of the page.
    private var unloadedIDs: Set<BrowserTabID> = []
    /// What the row of each unloaded tab keeps from its last page (its icon, and its title), by sidebar item, so it
    /// survives the window forgetting the tab's runtime ID while its Space is off screen. Dropped once the item
    /// leaves the store or its page loads again.
    private var kept: [SidebarItemID: KeptRow] = [:]
    /// The tab each row showed at the last refresh, by sidebar item.
    private var shownTabs: [SidebarItemID: BrowserTab] = [:]

    private struct KeptRow {
        var icon: (url: URL, image: NSImage)?
        var title: String
    }
    /// The runtime ID of each tab the window lists (the Favorites shown and the tabs of the Space on screen), as last
    /// shown.
    private var runtimeIDs: [SidebarItemID: BrowserTabID] = [:]
    /// The folders being deleted with their tabs, while their pages are asked to close.
    private var deletingFolders: Set<SidebarItemID> = []

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
        if event == .unloaded, let id = window.modelID(of: tab) { unloadedIDs.insert(id) }
        guard case .stateChanged(let state) = event, let id = window.modelID(of: tab) else { return }
        updateFavicon(of: id, tab: tab, url: state.faviconURL)
        refresh()
    }

    /// An unloaded tab keeps its row, so it keeps its icon and title too; the icon goes with a tab that closed.
    func tabDidClose(_ tab: any EngineTab) {
        guard let id = window.modelID(of: tab) else { return }
        let icon = favicons.removeValue(forKey: id)
        if unloadedIDs.remove(id) != nil, let item = window.sidebarItemID(for: id) {
            let title =
                tab.state.title.isEmpty ? (window.tabList.tabs.first { $0.id == id }?.title ?? "") : tab.state.title
            kept[item] = KeptRow(icon: icon, title: title)
        }
        // The page that loads again reports its icon address anew; the same address keeps the icon without a reload.
        faviconReported[id] = nil
    }

    /// The row's page loads again: it shows the kept icon until the page reports its own.
    func tabOpened(_ tab: any EngineTab, item: SidebarItemID) {
        guard let row = kept.removeValue(forKey: item), let id = window.modelID(of: tab), favicons[id] == nil else {
            return
        }
        favicons[id] = row.icon
    }

    /// Shows the window's sidebar with what each tab of the Space on screen last reported.
    private func refresh() {
        let list = window.tabList
        let graph = window.store.graph
        var tabs: [SidebarItemID: BrowserTab] = [:]
        runtimeIDs = [:]
        for var tab in list.tabs {
            guard let item = window.sidebarItemID(for: tab.id) else { continue }
            runtimeIDs[item] = tab.id
            if let row = kept[item] {
                if window.engineTab(for: tab.id) != nil {
                    // The page loaded again and owns its icon and title.
                    if favicons[tab.id] == nil { favicons[tab.id] = row.icon }
                    kept[item] = nil
                } else if !row.title.isEmpty {
                    // A tab the window rebuilt from its saved page shows the title its page had, not the saved one.
                    tab.title = row.title
                }
            }
            tabs[item] = tab
        }
        // A row that left the store takes what it kept with it.
        for item in kept.keys where graph[item] == nil { kept[item] = nil }
        shownTabs = tabs
        let active = list.activeID.flatMap { window.sidebarItemID(for: $0) }
        sidebar.show(SidebarContent(graph: graph, tabs: tabs, activeItem: active))
    }

    /// Moves tab `id` to `index` in the window's tab list, as dropping its row there does: to the place of the tab
    /// that is at `index` once `id` has left its own (in that tab's section or folder, so it pins or unpins when that
    /// is the other zone; the split's place for a tab inside a split), or to the end of today past the last tab.
    /// Returns whether it moved.
    @discardableResult
    func dropTab(_ id: BrowserTabID, atTabIndex index: Int) -> Bool {
        let graph = window.store.graph
        guard let item = window.sidebarItemID(for: id), let space = graph.activeSpace else { return false }
        let others = graph.tabIDs(in: space.id).filter { $0 != item }
        if others.indices.contains(index) {
            // A tab inside a split stands for its split: the drop goes to the split's place, as no tab joins a split.
            var target = others[index]
            if let parent = graph[target]?.parentID, case .split? = graph[parent]?.data, graph[item]?.parentID != parent
            {
                target = parent
            }
            if let parent = graph[target]?.parentID, let position = graph[parent]?.childrenIDs.firstIndex(of: target) {
                return sidebar.dragItem(item, into: parent, at: position)
            }
        }
        let today = space.unpinnedContainerID
        return sidebar.dragItem(item, into: today, at: graph[today]?.childrenIDs.count ?? 0)
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

    /// A loaded tab navigates. A tab without a page goes through `window.select(_:)`, which loads its saved page (for
    /// a pinned tab, its pinned address) as selecting any such tab does, and then navigates to `url` unless that is
    /// already the page it loaded.
    @discardableResult
    func load(_ item: SidebarItemID, url: URL) -> Bool {
        guard let id = runtimeIDs[item] else { return false }
        if let tab = window.engineTab(for: id), !tab.isClosed {
            tab.load(url)
            return true
        }
        // The address the window loads for a saved tab, as `select` is about to.
        let graph = window.store.graph
        let saved = graph.pinnedURL(of: item) ?? graph[item]?.tab?.savedPageURL
        window.select(id)
        guard let tab = window.engineTab(for: id), !tab.isClosed else { return false }
        if saved != url { tab.load(url) }
        return true
    }

    /// Shows the Favorite in place through `window.select(_:)`, which the window lists with the Space's tabs: its own
    /// page when it has one, else its saved address loads as its page. No other tab opens.
    @discardableResult
    func open(favorite item: SidebarItemID) -> Bool {
        // Only the Favorites the Space on screen shows, so the page loads in the profile it belongs to.
        let graph = window.store.graph
        guard let space = graph.activeSpaceID, graph.isInFavorites(item, shownBy: space), let id = runtimeIDs[item],
            // A Favorite with no saved address and no page has nothing to show.
            graph[item]?.tab?.savedPageURL != nil || window.engineTab(for: id) != nil
        else { return false }
        window.select(id)
        return window.tabList.activeID == id
    }

    @discardableResult
    func beginRename(_ item: SidebarItemID) -> Bool {
        sidebar.beginRename(item)
    }

    /// The folder's tabs go one at a time, each looked up again from the store, so a tab dragged in or out while a
    /// leave prompt waits is closed or left as it is then; each closed tab leaves the store right after closing (a
    /// pinned tab only unloads). Nothing else leaves the store until every open page has closed: the folder's tabs
    /// without a page go with the folder in the last change, so a page asking to stay keeps the folder and all it
    /// holds. The delete stops, keeping what is left, when the folder is no longer in the Space on screen (the person
    /// switched Space or dragged it to another), as only that Space's open pages can be found, and a folder is never
    /// deleted while a page in it may still be open. While it runs, a second delete of the folder, a folder inside it
    /// or one around it only beeps, so no page is asked twice.
    func deleteWithTabs(_ item: SidebarItemID) {
        let graph = window.store.graph
        guard case .folder? = graph[item]?.data, let space = graph.activeSpaceID,
            graph.spaceID(containing: item) == space
        else { return }
        guard
            !deletingFolders.contains(where: {
                $0 == item || graph.isDescendant($0, of: item) || graph.isDescendant(item, of: $0)
            })
        else {
            NSSound.beep()
            return
        }
        deletingFolders.insert(item)
        moveActiveTab(outOf: item, in: space)
        // Held strongly, as a close can free the window before the task runs.
        let owner = window
        Task { [weak self] in
            defer { self?.deletingFolders.remove(item) }
            // Whether the folder is still in the Space on screen, the only one whose open pages can be found.
            @MainActor func inPlace() -> Bool {
                let graph = owner.store.graph
                return graph[item] != nil && graph.activeSpaceID == space && graph.spaceID(containing: item) == space
            }
            while let self, inPlace() {
                let graph = owner.store.graph
                let inside = graph.tabIDs(in: space).filter { graph.isDescendant($0, of: item) }
                guard let (tab, id) = inside.lazy.compactMap({ tab in self.loadedID(of: tab).map { (tab, $0) } }).first
                else {
                    // No page in the folder is open: the folder goes with its saved tabs in one change.
                    owner.changeSidebar { try $0.apply([.delete(item)]) }
                    return
                }
                self.moveActiveTab(outOf: item, in: space)
                guard await owner.closeTab(id: id) else { return }
                // A pinned tab only unloads: it leaves the store unless its folder moved away during the prompt.
                guard inPlace() else { return }
                if owner.store.graph.isDescendant(tab, of: item) {
                    owner.changeSidebar { try $0.apply([.delete(tab)]) }
                }
            }
        }
    }

    /// The runtime ID of tab `item` while its page is loaded.
    private func loadedID(of item: SidebarItemID) -> BrowserTabID? {
        runtimeIDs[item].flatMap { window.engineTab(for: $0) != nil ? $0 : nil }
    }

    /// Makes the nearest tab after folder `item` (or before it) active when the active tab is inside the folder.
    private func moveActiveTab(outOf item: SidebarItemID, in space: SidebarSpaceID) {
        let graph = window.store.graph
        let ids = graph.tabIDs(in: space)
        guard let active = graph.activeTabID, graph.isDescendant(active, of: item),
            let position = ids.firstIndex(of: active)
        else { return }
        let after = ids[position...].first { !graph.isDescendant($0, of: item) }
        let before = ids[..<position].last { !graph.isDescendant($0, of: item) }
        if let next = after ?? before { select(next) }
    }

    func confirm(_ message: String, detail: String, action: String, confirmed: @escaping @MainActor () -> Void) {
        guard let sheetParent = window.window, sheetParent.attachedSheet == nil else {
            // Another sheet (a page's dialog) is up: the person hears that the action cannot ask now.
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        // Return answers Cancel, never the destructive action, which takes a click.
        let destructive = alert.addButton(withTitle: action)
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.beginSheetModal(for: sheetParent) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { confirmed() }
        }
    }

    func slideOutline(_ direction: SidebarSlideDirection, change: () -> Void) {
        sidebar.slideOutline(direction, change: change)
    }

    func sidebarNewTab() {
        window.newTab(sidebar)
    }

    func favicon(for item: SidebarItemID) -> NSImage? {
        runtimeIDs[item].flatMap { favicons[$0]?.image } ?? kept[item]?.icon?.image
    }

    /// The tab row `item` shows (its address and title), nil while the window lists no such row.
    func shownTab(for item: SidebarItemID) -> BrowserTab? {
        shownTabs[item]
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
