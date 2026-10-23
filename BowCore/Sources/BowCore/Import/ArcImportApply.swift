import Foundation

/// What one applied import added to the sidebar, enough to take it out again in one step.
public struct ArcImportApplied: Equatable, Sendable {
    /// The Spaces the import created, in order. Their pinned and unpinned items go with them.
    public var spaceIDs: [SidebarSpaceID] = []
    /// The Favorites the import added, in profile Favorites that existed or were created.
    public var favoriteItemIDs: [SidebarItemID] = []
    /// Every sidebar item the import inserted (folders, tabs and splits), Favorites included.
    public var itemCount = 0
    /// Set when the change is in the sidebar but writing the file failed. The store keeps retrying on its next save.
    public var saveFailure: String?

    public var isEmpty: Bool { spaceIDs.isEmpty && favoriteItemIDs.isEmpty }

    /// Takes the import out again in one undoable-style transaction: the Favorites it added and the Spaces it
    /// created, with whatever is still inside them. Anything already gone is skipped. Items the person moved out of
    /// the imported Spaces since stay where they are.
    ///
    /// An empty Favorites section that the import created for a new profile stays behind, exactly as it does when
    /// any Space of that profile is deleted.
    public func undo(on store: SidebarStore) throws {
        guard !isEmpty else { return }
        do {
            try store.transaction {
                for id in favoriteItemIDs where store.transactionGraph?.items[id] != nil {
                    try store.mutate(.delete(id))
                }
                for id in spaceIDs where store.transactionGraph?.space(id) != nil {
                    try store.mutate(.deleteSpace(id))
                }
            }
        } catch SidebarStoreError.saveFailed {
            // The change is committed in memory and the store retries the write, so the undo has happened.
        }
    }

    /// The same line `ArcImportPreview.summaryLine` gives, read back from the sidebar the import landed in.
    public func summaryLine(in graph: SidebarGraph) -> String {
        let trees = importedPinnedTrees(in: graph)
        return ArcImportPreview.summaryLine(
            pinnedTrees: trees, favoritesCount: favoriteItemIDs.filter { graph.items[$0] != nil }.count)
    }

    /// The imported Spaces' pinned items as preview nodes, for comparing with the preview the person approved.
    public func importedPinnedTrees(in graph: SidebarGraph) -> [[ArcImportPreviewNode]] {
        spaceIDs.compactMap { graph.space($0) }.map { space in
            graph.children(of: space.pinnedContainerID).map { Self.node($0, in: graph) }
        }
    }

    /// The imported Spaces' unpinned items as preview nodes.
    public func importedUnpinnedTrees(in graph: SidebarGraph) -> [[ArcImportPreviewNode]] {
        spaceIDs.compactMap { graph.space($0) }.map { space in
            graph.children(of: space.unpinnedContainerID).map { Self.node($0, in: graph) }
        }
    }

    static func node(_ item: SidebarItem, in graph: SidebarGraph) -> ArcImportPreviewNode {
        let children = graph.children(of: item.id).map { node($0, in: graph) }
        switch item.data {
        case .tab(let tab):
            var node = ArcImportPreviewNode(
                kind: .tab,
                title: ArcImportPreviewNode.displayTitle(custom: item.title, saved: tab.savedTitle, url: tab.savedURL),
                children: [])
            node.customName = item.title
            node.url = tab.savedURL
            node.savedTitle = tab.savedTitle
            return node
        case .folder:
            return ArcImportPreviewNode(kind: .folder, title: item.title ?? "", children: children)
        case .split(let split):
            return ArcImportPreviewNode(
                kind: .splitView, title: "Split view", orientation: split.orientation, children: children)
        case .container:
            return ArcImportPreviewNode(kind: .folder, title: item.title ?? "", children: children)
        }
    }
}

extension ArcImporter {
    /// Writes what the preview shows into `store` as one transaction: either everything arrives and the file is
    /// saved once, or nothing changes. The active Space and tab stay as they were. Undo it with the result's `undo`.
    ///
    /// Every imported Space is new and goes after the Spaces already there; nothing existing is changed apart from
    /// Favorites being added to the end of a profile's Favorites. Applying an empty preview does nothing.
    @discardableResult
    public static func apply(_ preview: ArcImportPreview, to store: SidebarStore) throws -> ArcImportApplied {
        var applied = ArcImportApplied()
        guard !preview.isEmpty else { return applied }
        do {
            try store.transaction {
                var profileOfArcSpace: [String: SidebarProfileID] = [:]
                for entry in preview.spaces {
                    let id = SidebarSpaceID.make()
                    let profile: SidebarProfileID
                    switch entry.profile {
                    case .defaultProfile: profile = .default
                    case .arcProfile(let existing): profile = existing
                    case .separateProfile: profile = .make()
                    }
                    try store.mutate(.insertSpace(id, title: entry.title, profileID: profile))
                    profileOfArcSpace[entry.arcID] = profile
                    applied.spaceIDs.append(id)
                    guard let space = store.transactionGraph?.space(id) else {
                        throw SidebarStoreError.spaceNotFound(id)
                    }
                    for node in entry.pinned {
                        try insert(node, under: space.pinnedContainerID, in: store, count: &applied.itemCount)
                    }
                    for node in entry.unpinned {
                        try insert(node, under: space.unpinnedContainerID, in: store, count: &applied.itemCount)
                    }
                }
                for entry in preview.favorites {
                    let profile: SidebarProfileID
                    switch entry.profile {
                    case .defaultProfile: profile = .default
                    case .arcProfile(let existing): profile = existing
                    case .separateProfile:
                        guard let owner = entry.forArcSpaceID, let own = profileOfArcSpace[owner] else {
                            throw SidebarStoreError.invalidHierarchy("favorites copy has no Space to belong to")
                        }
                        profile = own
                    }
                    guard let container = store.transactionGraph?.favoritesContainerIDs[profile] else {
                        throw SidebarStoreError.invalidHierarchy("profile \(profile) has no favorites")
                    }
                    for node in entry.items {
                        let item = try insert(node, under: container, in: store, count: &applied.itemCount)
                        applied.favoriteItemIDs.append(item)
                    }
                }
            }
        } catch SidebarStoreError.saveFailed(let reason) {
            applied.saveFailure = reason
        }
        return applied
    }

    /// Parses nothing and reads no file: plans and applies an already parsed result in one call.
    @discardableResult
    public static func apply(_ result: ArcImportResult, plan: ArcImportPlan, to store: SidebarStore) throws
        -> ArcImportApplied
    {
        try apply(preview(result, plan: plan), to: store)
    }

    /// Inserts a node and everything under it, returning the new item's ID.
    @discardableResult
    private static func insert(
        _ node: ArcImportPreviewNode, under parent: SidebarItemID, in store: SidebarStore, count: inout Int
    )
        throws -> SidebarItemID
    {
        let item: SidebarItem
        switch node.kind {
        case .tab: item = .tab(url: node.url ?? "", title: node.savedTitle, customTitle: node.customName)
        case .folder: item = .folder(title: node.title)
        case .splitView: item = .split(orientation: node.orientation ?? .horizontal)
        }
        try store.mutate(.insert(item, parent: parent))
        count += 1
        for child in node.children { try insert(child, under: item.id, in: store, count: &count) }
        return item.id
    }
}
