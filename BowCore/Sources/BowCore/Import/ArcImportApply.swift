import Foundation

/// What one applied import added to the sidebar, enough to take it out again in one step.
public struct ArcImportApplied: Equatable, Sendable {
    /// The Spaces the import created, in order.
    public var spaceIDs: [SidebarSpaceID] = []
    /// The Favorites the import added, in profile Favorites that existed or were created.
    public var favoriteItemIDs: [SidebarItemID] = []
    /// The Favorites section each of `favoriteItemIDs` was added to.
    public var favoriteContainerIDs: [SidebarItemID: SidebarItemID] = [:]
    /// Every item the import inserted into the Spaces it created (folders, tabs and splits), and nothing else.
    /// Undo removes only these, so whatever else sits in an imported Space is not the import's to delete.
    public var spaceItemIDs: [SidebarItemID] = []
    /// Set when the change is in the sidebar but writing the file failed. The store keeps retrying on its next save.
    public var saveFailure: String?

    /// Every sidebar item the import inserted, Favorites included.
    public var itemCount: Int { spaceItemIDs.count + favoriteItemIDs.count }

    public var isEmpty: Bool { spaceIDs.isEmpty && favoriteItemIDs.isEmpty }

    /// Takes the import out again in one transaction, without touching anything the person added or moved since.
    ///
    /// - The Favorites the import added are deleted, unless the person moved one out of the Favorites section it was
    ///   added to, which keeps it where it is now.
    /// - In each imported Space, exactly the items the import inserted are deleted. Anything else found there (an
    ///   existing tab or folder the person moved in, a tab opened there since) moves, with what is inside it, to the
    ///   end of the same section (pinned or unpinned) of the first Space that is not an imported one, in the order it
    ///   had. Then the imported Space is deleted. If an imported Space was on screen, that first Space comes on
    ///   screen instead. The kept items change profile when the imported Space had one of its own.
    /// - Items of the import that the person moved out of an imported Space stay where they are. Anything already
    ///   gone is skipped.
    ///
    /// Throws `ArcImportUndoError.noOtherSpaceRemains` and changes nothing when no Space other than the imported
    /// ones is left to take over what the person added. A failure to write the file does not undo the undo: the
    /// change is in the sidebar and the result carries the failure, as `ArcImporter.apply` does.
    ///
    /// An empty Favorites section that the import created for a new profile stays behind, as it does when any Space
    /// of that profile is deleted: the sidebar has no change that removes a section.
    @discardableResult
    public func undo(on store: SidebarStore) throws -> ArcImportUndone {
        var undone = ArcImportUndone()
        guard !isEmpty else { return undone }
        let imported = Set(spaceItemIDs)
        let importedSpaces = Set(spaceIDs)
        do {
            try store.transaction {
                guard let before = store.transactionGraph else { throw SidebarStoreError.noOpenTransaction }
                for id in favoriteItemIDs {
                    guard let item = before.items[id], item.parentID == favoriteContainerIDs[id] else { continue }
                    try store.mutate(.delete(id))
                }
                let present = spaceIDs.compactMap { before.space($0) }
                if !present.isEmpty {
                    guard let destination = before.spaces.first(where: { !importedSpaces.contains($0.id) }) else {
                        throw ArcImportUndoError.noOtherSpaceRemains
                    }
                    undone.destinationSpaceID = destination.id
                    for space in present {
                        let sections = [
                            (space.pinnedContainerID, destination.pinnedContainerID),
                            (space.unpinnedContainerID, destination.unpinnedContainerID),
                        ]
                        for (source, target) in sections {
                            for id in Self.foreignRoots(under: source, importedItems: imported, in: before) {
                                try store.mutate(.move(id, parent: target))
                                undone.keptItemIDs.append(id)
                            }
                        }
                    }
                    // Deleting the Space on screen would otherwise pick a neighbour, which may be another imported
                    // Space. The person lands in the Space that took over their items instead, with a tab they
                    // had selected in the imported Space still selected.
                    if let active = before.activeSpaceID, importedSpaces.contains(active) {
                        try store.mutate(.setActiveSpace(destination.id))
                    }
                    for space in present { try store.mutate(.deleteSpace(space.id)) }
                    try store.mutate(.reconcileSelectedTab)
                }
                if let after = store.transactionGraph {
                    undone.removedItemIDs = before.orderedIDs().filter {
                        before.items[$0]?.data.isContainer == false && after.items[$0] == nil
                    }
                }
            }
        } catch SidebarStoreError.saveFailed(let reason) {
            // The change is committed in memory and the store retries the write, so the undo has happened.
            undone.saveFailure = reason
        }
        return undone
    }

    /// The topmost items under `container` that the import did not insert, in sidebar order. Items the import
    /// inserted are looked through, because the person may have put something inside one of them; foreign items are
    /// not looked into, since they move whole.
    private static func foreignRoots(
        under container: SidebarItemID, importedItems: Set<SidebarItemID>, in graph: SidebarGraph
    ) -> [SidebarItemID] {
        var roots: [SidebarItemID] = []
        func visit(_ id: SidebarItemID) {
            for child in graph.children(of: id) {
                if importedItems.contains(child.id) { visit(child.id) } else { roots.append(child.id) }
            }
        }
        visit(container)
        return roots
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
                        try insert(node, under: space.pinnedContainerID, in: store, into: &applied.spaceItemIDs)
                    }
                    for node in entry.unpinned {
                        try insert(node, under: space.unpinnedContainerID, in: store, into: &applied.spaceItemIDs)
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
                        var inserted: [SidebarItemID] = []
                        try insert(node, under: container, in: store, into: &inserted)
                        applied.favoriteItemIDs.append(contentsOf: inserted)
                        for id in inserted { applied.favoriteContainerIDs[id] = container }
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

    /// Inserts a node and everything under it, adding each new item's ID to `inserted`.
    private static func insert(
        _ node: ArcImportPreviewNode, under parent: SidebarItemID, in store: SidebarStore,
        into inserted: inout [SidebarItemID]
    ) throws {
        let item: SidebarItem
        switch node.kind {
        case .tab: item = .tab(url: node.url ?? "", title: node.savedTitle, customTitle: node.customName)
        case .folder: item = .folder(title: node.title)
        case .splitView: item = .split(orientation: node.orientation ?? .horizontal)
        }
        try store.mutate(.insert(item, parent: parent))
        inserted.append(item.id)
        for child in node.children { try insert(child, under: item.id, in: store, into: &inserted) }
    }
}

/// Why an import could not be undone. Nothing in the sidebar changed.
public enum ArcImportUndoError: Error, Equatable, CustomStringConvertible {
    /// Only imported Spaces are left, so there is no Space to keep what the person added to them.
    case noOtherSpaceRemains

    public var description: String {
        switch self {
        case .noOtherSpaceRemains:
            "the imported Spaces are the only Spaces left, so undoing would have no Space to keep your own tabs in"
        }
    }
}

/// What an undo did beyond removing the import.
public struct ArcImportUndone: Equatable, Sendable {
    /// Items that were not the import's (found inside an imported Space) and moved, with what is inside them, to the
    /// end of the same section of `destinationSpaceID`.
    public var keptItemIDs: [SidebarItemID] = []
    /// The Space that took them, nil when no imported Space was left to undo.
    public var destinationSpaceID: SidebarSpaceID?
    /// The folders, tabs and splits the undo deleted, so the app can close the pages of the tabs among them.
    public var removedItemIDs: [SidebarItemID] = []
    /// Set when the change is in the sidebar but writing the file failed. The store keeps retrying on its next save.
    public var saveFailure: String?
}
