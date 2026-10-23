import Foundation

/// What closing a tab does to its sidebar item.
public enum TabCloseOutcome: Equatable, Sendable {
    /// The page is closed and the item leaves the sidebar.
    case removeFromSidebar
    /// The page is unloaded but the item stays, with its saved address and title untouched. Selecting it later loads
    /// the saved address again.
    case unloadKeepingInSidebar
}

// MARK: Saved address of a tab

extension SidebarTab {
    /// The saved address as a URL, or nil when nothing usable was saved.
    public var savedPageURL: URL? {
        let text = savedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : URL(string: text)
    }

    /// Whether a page showing `liveURL` has left the page this tab was saved on. This is the shared rule for every tab
    /// that returns to a saved address (pinned tabs, and Favorites).
    ///
    /// The comparison ignores what is not a different page: letter case of the scheme and host, a default port, an empty
    /// path versus "/", and a `#fragment`. A different path or query counts as a different page. A tab with no live
    /// page (not loaded yet, or unloaded) or with no saved address has not navigated away.
    public func hasNavigatedAway(from liveURL: URL?) -> Bool {
        guard let liveURL else { return false }
        let saved = savedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { return false }
        return Self.comparisonKey(saved) != Self.comparisonKey(liveURL.absoluteString)
    }

    private static func comparisonKey(_ text: String) -> String {
        guard var parts = URLComponents(string: text) else { return text }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        let defaultPorts = ["http": 80, "https": 443]
        if let port = parts.port, let scheme = parts.scheme, defaultPorts[scheme] == port { parts.port = nil }
        if parts.percentEncodedPath.isEmpty, parts.host != nil { parts.percentEncodedPath = "/" }
        return parts.string ?? text
    }
}

// MARK: Reading pinned tabs

extension SidebarGraph {
    /// Whether `id` is a tab in some Space's pinned section, directly or inside a folder or split there.
    public func isPinned(_ id: SidebarItemID) -> Bool {
        guard items[id]?.data.isTab == true else { return false }
        return spaces.contains { isDescendant(id, of: $0.pinnedContainerID) }
    }

    /// The pinned tabs of a Space in sidebar order, including those inside folders and splits.
    public func pinnedTabIDs(in spaceID: SidebarSpaceID) -> [SidebarItemID] {
        tabIDs(in: spaceID).filter { isPinned($0) }
    }

    /// Whether a pinned tab showing `liveURL` has left its saved address, which is when the sidebar offers "Back to
    /// pinned URL". False for a tab that is not pinned.
    public func hasNavigatedAwayFromPinnedURL(_ id: SidebarItemID, liveURL: URL?) -> Bool {
        guard isPinned(id), let tab = items[id]?.tab else { return false }
        return tab.hasNavigatedAway(from: liveURL)
    }

    /// The address a pinned tab loads for "Back to pinned URL" and when it is selected after being closed: its saved
    /// address, never the page it was last showing. Nil for a tab that is not pinned or has no usable saved address.
    /// Asking changes nothing; the app loads the address.
    public func pinnedURL(of id: SidebarItemID) -> URL? {
        guard isPinned(id) else { return nil }
        return items[id]?.tab?.savedPageURL
    }

    /// What closing a tab does to its item: a pinned tab only unloads and stays in the sidebar, any other tab leaves.
    public func closeOutcome(for id: SidebarItemID) -> TabCloseOutcome {
        isPinned(id) ? .unloadKeepingInSidebar : .removeFromSidebar
    }
}

// MARK: Changing pinned tabs

extension SidebarStore {
    /// Pins a tab: moves it to the pinned section of its Space (the active Space for a Favorites tab) at `index` (nil
    /// puts it last), alone, even when it came out of a folder. When `page` is given, that live page becomes the saved
    /// address and title, the page the tab will return to; without it the tab keeps what it was saved with.
    /// Returns false, changing nothing (the saved address included), when the tab is already pinned.
    /// A tab inside a split cannot be pinned by itself.
    @discardableResult
    public func pinTab(_ id: SidebarItemID, page: (url: URL, title: String)? = nil, at index: Int? = nil) throws
        -> Bool
    {
        let graph = self.graph
        try requireTab(id, in: graph)
        guard !graph.isPinned(id) else { return false }
        try requireNotInSplit(id, in: graph)
        guard let spaceID = graph.spaceID(containing: id) ?? graph.activeSpaceID, let space = graph.space(spaceID)
        else { throw SidebarStoreError.invalidHierarchy("there is no space to pin \(id) into") }
        try transaction {
            if let page { try mutate(.setSavedPage(id, url: page.url.absoluteString, title: page.title)) }
            try mutate(.move(id, parent: space.pinnedContainerID, index: index))
            try mutate(.reconcileSelectedTab)
        }
        return true
    }

    /// Unpins a tab: moves it to the top of the tabs section of its Space (or at `index`). When `page` is given, that
    /// live page is recorded as the tab's saved page, so the tab stays on it after a relaunch instead of jumping back
    /// to the address it was pinned on. Returns false, changing nothing, when the tab is not pinned.
    @discardableResult
    public func unpinTab(_ id: SidebarItemID, page: (url: URL, title: String)? = nil, at index: Int? = 0) throws
        -> Bool
    {
        let graph = self.graph
        try requireTab(id, in: graph)
        guard graph.isPinned(id), let spaceID = graph.spaceID(containing: id), let space = graph.space(spaceID)
        else { return false }
        try requireNotInSplit(id, in: graph)
        try transaction {
            if let page { try mutate(.setSavedPage(id, url: page.url.absoluteString, title: page.title)) }
            try mutate(.move(id, parent: space.unpinnedContainerID, index: index))
        }
        return true
    }

    /// Moves a pinned tab to `index` among the items it shares a parent with (counted after it leaves its place), for
    /// reordering the pinned section or a folder in it.
    public func reorderPinnedTab(_ id: SidebarItemID, to index: Int) throws {
        let graph = self.graph
        try requireTab(id, in: graph)
        guard graph.isPinned(id), let parent = graph[id]?.parentID else {
            throw SidebarStoreError.invalidHierarchy("\(id) is not pinned")
        }
        try transaction { try mutate(.move(id, parent: parent, index: index)) }
    }

    /// "Replace pinned URL with current": makes the page the tab is showing its new saved address and title. This is
    /// the only way a pinned tab's saved address changes besides pinning; browsing never does it.
    public func replacePinnedURL(_ id: SidebarItemID, with page: (url: URL, title: String)) throws {
        let graph = self.graph
        try requireTab(id, in: graph)
        guard graph.isPinned(id) else { throw SidebarStoreError.invalidHierarchy("\(id) is not pinned") }
        try transaction { try mutate(.setSavedPage(id, url: page.url.absoluteString, title: page.title)) }
    }

    private func requireTab(_ id: SidebarItemID, in graph: SidebarGraph) throws {
        guard let item = graph[id] else { throw SidebarStoreError.itemNotFound(id) }
        guard item.data.isTab else { throw SidebarStoreError.invalidHierarchy("\(id) is not a tab") }
    }

    private func requireNotInSplit(_ id: SidebarItemID, in graph: SidebarGraph) throws {
        guard let parentID = graph[id]?.parentID, case .split? = graph[parentID]?.data else { return }
        throw SidebarStoreError.invalidHierarchy("\(id) is in a split view, so it cannot move alone")
    }
}
