import Foundation

/// One row the sidebar shows: an item and how deep it sits below its section (0 for a direct child of the pinned or
/// tabs section).
public struct SidebarRow: Equatable, Sendable {
    public var id: SidebarItemID
    public var depth: Int

    public init(id: SidebarItemID, depth: Int) {
        self.id = id
        self.depth = depth
    }
}

// MARK: Reading what is visible

extension SidebarGraph {
    /// The rows a Space shows in sidebar order: its pinned section, then its tabs section, each depth first. The
    /// children of a collapsed folder are left out, at any depth. A split view's tabs are always shown. Favorites are
    /// not rows of a Space and are left out.
    public func visibleRows(in spaceID: SidebarSpaceID) -> [SidebarRow] {
        guard let space = space(spaceID) else { return [] }
        var rows: [SidebarRow] = []
        var seen: Set<SidebarItemID> = []
        func visit(_ id: SidebarItemID, depth: Int) {
            guard let item = items[id], seen.insert(id).inserted else { return }
            rows.append(SidebarRow(id: id, depth: depth))
            if case .folder(let folder) = item.data, !folder.isExpanded { return }
            for child in item.childrenIDs { visit(child, depth: depth + 1) }
        }
        for section in [space.pinnedContainerID, space.unpinnedContainerID] {
            for child in items[section]?.childrenIDs ?? [] { visit(child, depth: 0) }
        }
        return rows
    }

    /// Whether `id` is shown as a row of its Space: every folder above it is expanded. False for an item that is in no
    /// Space (Favorites, a section) or does not exist.
    public func isVisible(_ id: SidebarItemID) -> Bool {
        guard let spaceID = spaceID(containing: id), items[id]?.data.isContainer == false else { return false }
        return visibleRows(in: spaceID).contains { $0.id == id }
    }

    /// The folders above `id`.
    fileprivate func folderAncestors(of id: SidebarItemID) -> [SidebarItemID] {
        var result: [SidebarItemID] = []
        var current = items[id]?.parentID
        var steps = 0
        while let next = current, let item = items[next], steps <= items.count {
            if case .folder = item.data { result.append(next) }
            current = item.parentID
            steps += 1
        }
        return result
    }

    /// Every folder in a Space's pinned and tabs sections, at any depth.
    fileprivate func folderIDs(in space: SidebarSpace) -> [SidebarItemID] {
        var result: [SidebarItemID] = []
        var seen: Set<SidebarItemID> = []
        func visit(_ id: SidebarItemID) {
            guard let item = items[id], seen.insert(id).inserted else { return }
            if case .folder = item.data { result.append(id) }
            item.childrenIDs.forEach(visit)
        }
        visit(space.pinnedContainerID)
        visit(space.unpinnedContainerID)
        return result
    }
}

// MARK: Collapsing and expanding

extension SidebarStore {
    /// Collapses every folder of a Space (the one on screen unless `spaceID` is given), pinned and tabs sections
    /// alike, in one transaction, so it is saved as one change.
    ///
    /// The tab that is selected stays visible: when it sits in this Space, the folders above it stay open, and any of
    /// them that was closed is opened again. (Arc does the same: collapsing never hides the selected tab.) When the
    /// selected tab is in another Space, in Favorites or missing, every folder collapses.
    ///
    /// Returns the number of folders that were open and are now closed, which is 0 when there was nothing to
    /// collapse. Folders already closed stay closed and count for nothing.
    @discardableResult
    public func collapseAllFolders(in spaceID: SidebarSpaceID? = nil) throws -> Int {
        let graph = self.graph
        guard let id = spaceID ?? graph.activeSpaceID, let space = graph.space(id) else {
            throw SidebarStoreError.spaceNotFound(spaceID ?? "none")
        }
        var keepOpen: Set<SidebarItemID> = []
        if let active = graph.activeTabID, graph.spaceID(containing: active) == id {
            keepOpen = Set(graph.folderAncestors(of: active))
        }
        var collapsed = 0
        try transaction {
            for folderID in graph.folderIDs(in: space) {
                guard case .folder(let folder)? = graph[folderID]?.data else { continue }
                let shouldBeExpanded = keepOpen.contains(folderID)
                guard folder.isExpanded != shouldBeExpanded else { continue }
                try mutate(.setFolderExpanded(folderID, shouldBeExpanded))
                if !shouldBeExpanded { collapsed += 1 }
            }
        }
        return collapsed
    }

    /// Opens every folder of a Space (the one on screen unless `spaceID` is given) in one transaction. Returns the
    /// number of folders that were closed and are now open.
    @discardableResult
    public func expandAllFolders(in spaceID: SidebarSpaceID? = nil) throws -> Int {
        let graph = self.graph
        guard let id = spaceID ?? graph.activeSpaceID, let space = graph.space(id) else {
            throw SidebarStoreError.spaceNotFound(spaceID ?? "none")
        }
        var expanded = 0
        try transaction {
            for folderID in graph.folderIDs(in: space) {
                guard case .folder(let folder)? = graph[folderID]?.data, !folder.isExpanded else { continue }
                try mutate(.setFolderExpanded(folderID, true))
                expanded += 1
            }
        }
        return expanded
    }
}
