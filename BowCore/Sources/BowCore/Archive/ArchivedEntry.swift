import Foundation

/// One archived item and everything needed to put it back exactly where it was.
public struct ArchivedEntry: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// The auto-archive timer expired it.
        case auto
        /// The person archived it.
        case manual
    }

    /// Where the item sat when it was archived.
    public struct Source: Codable, Hashable, Sendable {
        /// The Space the item belonged to, as an opaque ID. The Space may be gone by the time the item is put back.
        public var spaceID: String
        /// The folder, split or section that held the item.
        public var parentID: SidebarItemID
        /// The item's position among its parent's children.
        public var index: Int

        public init(spaceID: String, parentID: SidebarItemID, index: Int) {
            self.spaceID = spaceID
            self.parentID = parentID
            self.index = index
        }
    }

    /// The archived item as it was, with its own ID and custom title.
    public var item: SidebarItem
    /// What hung under the item (a split's tabs, a folder's contents), in depth first order, each with its children
    /// lists intact. Empty for a tab.
    public var descendants: [SidebarItem]
    public var archivedAt: Date
    public var reason: Reason
    public var source: Source

    public var id: SidebarItemID { item.id }

    public init(
        item: SidebarItem, descendants: [SidebarItem] = [], archivedAt: Date, reason: Reason, source: Source
    ) {
        self.item = item
        self.descendants = descendants
        self.archivedAt = archivedAt
        self.reason = reason
        self.source = source
    }

    /// The tab's saved address, or nil when the item is not a tab. Handy for listing.
    public var savedURL: String? { item.tab?.savedURL }
}

extension SidebarItemData {
    fileprivate var isSplit: Bool {
        if case .split = self { return true }
        return false
    }
}

extension SidebarGraph {
    /// The kind of section an item hangs under and the Space that owns it. Nil for an unreachable item; Favorites
    /// has no Space.
    func section(of id: SidebarItemID) -> (kind: SidebarContainer.Kind, space: SidebarSpace?)? {
        var current: SidebarItemID? = id
        var steps = 0
        while let next = current, let item = items[next], steps <= items.count {
            if case .container(let container) = item.data {
                return (container.kind, spaces.first { $0.pinnedContainerID == next || $0.unpinnedContainerID == next })
            }
            current = item.parentID
            steps += 1
        }
        return nil
    }

    /// The item and everything under it, depth first.
    func subtree(of id: SidebarItemID) -> [SidebarItem] {
        var result: [SidebarItem] = []
        var seen: Set<SidebarItemID> = []
        func visit(_ id: SidebarItemID) {
            guard let item = items[id], seen.insert(id).inserted else { return }
            result.append(item)
            item.childrenIDs.forEach(visit)
        }
        visit(id)
        return result
    }
}

extension ArchivedEntry {
    /// Records `id` and its subtree from `graph`. Only items in a Space's Today section (its unpinned container) may
    /// be archived: pinned items and Favorites never are.
    static func capture(
        _ id: SidebarItemID, from graph: SidebarGraph, reason: Reason, at date: Date
    ) throws(ArchiveError) -> ArchivedEntry {
        guard let item = graph[id] else { throw .itemNotFound(id) }
        guard !item.data.isContainer, let parentID = item.parentID, let parent = graph[parentID] else {
            throw .notEligible(id, "it is not an item in a section")
        }
        guard !(parent.data.isSplit) else {
            throw .notEligible(id, "it is part of a split; archive the split instead")
        }
        guard let section = graph.section(of: id), section.kind == .unpinned, let space = section.space else {
            throw .notEligible(id, "only items in Today can be archived")
        }
        let nodes = graph.subtree(of: id)
        return ArchivedEntry(
            item: nodes[0], descendants: Array(nodes.dropFirst()), archivedAt: date, reason: reason,
            source: Source(
                spaceID: space.id.rawValue, parentID: parentID,
                index: parent.childrenIDs.firstIndex(of: id) ?? parent.childrenIDs.count))
    }

    /// The mutations that put the item back: into its old parent at its old position, or at the top of the source
    /// Space's Today when that parent is gone, or of the first Space's Today when the Space is gone too.
    func putBackMutations(into graph: SidebarGraph) throws(ArchiveError) -> [SidebarMutation] {
        for node in [item] + descendants where graph[node.id] != nil { throw .alreadyInSidebar(node.id) }

        var parent = source.parentID
        var index: Int? = source.index
        if graph.section(of: parent)?.kind != .unpinned || graph[parent]?.data.canHold(item.data) != true {
            let space = graph.spaces.first { $0.id.rawValue == source.spaceID } ?? graph.spaces.first
            guard let space else { throw .noPlaceToPutBack(id) }
            parent = space.unpinnedContainerID
            index = 0
        }
        if let position = index, let count = graph[parent]?.childrenIDs.count { index = min(position, count) }

        var mutations: [SidebarMutation] = [.insert(withoutChildren(item), parent: parent, index: index)]
        for node in descendants {
            guard let nodeParent = node.parentID else { throw .invalidEntry(id, "\(node.id) has no parent") }
            mutations.append(.insert(withoutChildren(node), parent: nodeParent))
        }
        return mutations
    }

    /// Children are rebuilt by inserting them in order, so each inserted record carries none.
    private func withoutChildren(_ node: SidebarItem) -> SidebarItem {
        var copy = node
        copy.childrenIDs = []
        return copy
    }
}

/// Why an archive operation was refused.
public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    case itemNotFound(SidebarItemID)
    /// Pinned items, Favorites and sections cannot be archived.
    case notEligible(SidebarItemID, String)
    case entryNotFound(SidebarItemID)
    /// An item with this ID is back in the sidebar already.
    case alreadyInSidebar(SidebarItemID)
    case noPlaceToPutBack(SidebarItemID)
    case invalidEntry(SidebarItemID, String)
    case saveFailed(String)
    /// The archive file could not be read and could not be moved aside, so the store refuses to start rather than
    /// risk overwriting it.
    case unreadableFileNotSetAside(String)
    case backupFailed(String)
    /// The archive file was written by a newer Bow, in format `version`, while this build reads up to `readable`.
    /// The store refuses to open it and leaves it where it is, so the newer Bow still finds it.
    case fileFromNewerBuild(version: Int, readable: Int)

    public var description: String {
        switch self {
        case .itemNotFound(let id): return "item \(id) not found"
        case .notEligible(let id, let reason): return "item \(id) cannot be archived: \(reason)"
        case .entryNotFound(let id): return "no archived item \(id)"
        case .alreadyInSidebar(let id): return "item \(id) is already in the sidebar"
        case .noPlaceToPutBack(let id): return "no Space to put \(id) back into"
        case .invalidEntry(let id, let reason): return "archived item \(id) is damaged: \(reason)"
        case .saveFailed(let reason): return "saving the archive failed: \(reason)"
        case .unreadableFileNotSetAside(let reason):
            return "the unreadable archive file could not be set aside: \(reason)"
        case .backupFailed(let reason): return "the archive file could not be copied before changing it: \(reason)"
        case .fileFromNewerBuild(let version, let readable):
            return "the archive file is format \(version), from a newer Bow; this build reads up to \(readable)"
        }
    }
}
