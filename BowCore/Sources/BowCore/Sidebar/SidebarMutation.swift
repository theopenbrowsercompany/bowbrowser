import Foundation

/// Why the store refused a request. Apart from `saveFailed`, the store is left exactly as it was before the call.
public enum SidebarStoreError: Error, Equatable, CustomStringConvertible {
    /// A transaction was begun while another one was open.
    case nestedTransaction
    /// A mutation or commit was attempted without an open transaction.
    case noOpenTransaction
    /// A save or repair was attempted while a transaction was open.
    case transactionInProgress
    case itemNotFound(SidebarItemID)
    case itemAlreadyExists(SidebarItemID)
    case spaceNotFound(SidebarSpaceID)
    case spaceAlreadyExists(SidebarSpaceID)
    case invalidIndex(Int)
    case invalidHierarchy(String)
    /// The last Space cannot be deleted: the sidebar always has one.
    case lastSpace
    /// The transaction would have left the graph broken, so it was rolled back.
    case integrityCheckFailed([String])
    /// The change is kept in memory and marked unsaved, but writing the file failed.
    case saveFailed(String)
    /// The sidebar file could not be read and could not be moved aside, so the store refuses to start rather than
    /// risk overwriting it.
    case unreadableFileNotSetAside(String)
    /// The file had to be migrated or repaired on open but could not be copied first, so the store refuses to start
    /// rather than later replace the only copy.
    case backupFailed(String)

    public var description: String {
        switch self {
        case .nestedTransaction: return "nested transactions are not supported"
        case .noOpenTransaction: return "no transaction is open"
        case .transactionInProgress: return "a transaction is open"
        case .itemNotFound(let id): return "item \(id) not found"
        case .itemAlreadyExists(let id): return "item \(id) already exists"
        case .spaceNotFound(let id): return "space \(id) not found"
        case .spaceAlreadyExists(let id): return "space \(id) already exists"
        case .invalidIndex(let index): return "index \(index) is out of range"
        case .invalidHierarchy(let reason): return "invalid hierarchy: \(reason)"
        case .lastSpace: return "the last space cannot be deleted"
        case .integrityCheckFailed(let problems): return "integrity check failed: \(problems.joined(separator: "; "))"
        case .saveFailed(let reason): return "saving the sidebar failed: \(reason)"
        case .unreadableFileNotSetAside(let reason):
            return "the unreadable sidebar file could not be set aside: \(reason)"
        case .backupFailed(let reason):
            return "the sidebar file could not be copied before changing it: \(reason)"
        }
    }
}

/// One change to the sidebar. Mutations are applied only inside a store transaction.
public enum SidebarMutation: Equatable, Sendable {
    /// Adds a new item with no children under `parent` at `index` (nil appends). Its `parentID` is set for it.
    case insert(SidebarItem, parent: SidebarItemID, index: Int? = nil)
    /// Moves an item and everything under it to `parent` at `index`, counted after it leaves its old place.
    case move(SidebarItemID, parent: SidebarItemID, index: Int? = nil)
    /// Deletes an item and everything under it.
    case delete(SidebarItemID)
    /// Deletes a folder but keeps what is inside it: its children take the folder's place, in their order, under the
    /// folder's parent. Only folders can be deleted this way.
    case deleteFolderKeepingChildren(SidebarItemID)
    /// Sets or clears an item's custom name.
    case rename(SidebarItemID, title: String?)
    /// Replaces a tab's saved address and title, the page it returns to. The app calls this only on purpose (pinning,
    /// "change saved address", or an unpinned tab's navigation it chooses to record), never as a mirror of the live page.
    case setSavedPage(SidebarItemID, url: String, title: String)
    case setFolderExpanded(SidebarItemID, Bool)
    case setSplitOrientation(SidebarItemID, SidebarSplit.Orientation)
    /// Adds a Space with new empty pinned and unpinned sections at `index` (nil appends).
    case insertSpace(SidebarSpaceID, title: String, index: Int? = nil)
    /// Deletes a Space and everything in its sections.
    case deleteSpace(SidebarSpaceID)
    case moveSpace(SidebarSpaceID, index: Int)
    case renameSpace(SidebarSpaceID, title: String)
    case setActiveSpace(SidebarSpaceID)
    case setActiveTab(SidebarItemID?)
}

extension SidebarGraph {
    /// Applies one mutation. On error the graph is unchanged.
    mutating func apply(_ mutation: SidebarMutation) throws(SidebarStoreError) {
        var next = self
        try next.applyInPlace(mutation)
        self = next
    }

    private mutating func applyInPlace(_ mutation: SidebarMutation) throws(SidebarStoreError) {
        switch mutation {
        case .insert(var item, let parentID, let index):
            guard items[item.id] == nil else { throw .itemAlreadyExists(item.id) }
            guard item.childrenIDs.isEmpty else {
                throw .invalidHierarchy("insert items one at a time, without children")
            }
            let parent = try existing(parentID)
            guard parent.data.canHold(item.data) else { throw .invalidHierarchy("\(parentID) cannot hold \(item.id)") }
            item.parentID = parentID
            items[item.id] = item
            try insertChild(item.id, into: parentID, at: index)

        case .move(let id, let parentID, let index):
            let item = try existing(id)
            let parent = try existing(parentID)
            guard !item.data.isContainer else { throw .invalidHierarchy("sections cannot move") }
            guard parent.data.canHold(item.data) else { throw .invalidHierarchy("\(parentID) cannot hold \(id)") }
            guard !isDescendant(parentID, of: id) else { throw .invalidHierarchy("\(id) cannot move inside itself") }
            if let oldParentID = item.parentID { items[oldParentID]?.childrenIDs.removeAll { $0 == id } }
            items[id]?.parentID = parentID
            try insertChild(id, into: parentID, at: index)

        case .delete(let id):
            let item = try existing(id)
            guard !item.data.isContainer else { throw .invalidHierarchy("sections are deleted with their space") }
            if let parentID = item.parentID { items[parentID]?.childrenIDs.removeAll { $0 == id } }
            removeSubtree(id)

        case .deleteFolderKeepingChildren(let id):
            let folder = try existing(id)
            guard case .folder = folder.data else { throw .invalidHierarchy("\(id) is not a folder") }
            guard let parentID = folder.parentID, let parent = items[parentID],
                let position = parent.childrenIDs.firstIndex(of: id)
            else { throw .invalidHierarchy("\(id) has no place to leave its children in") }
            let children = folder.childrenIDs
            for childID in children {
                guard let child = items[childID], parent.data.canHold(child.data) else {
                    throw .invalidHierarchy("\(parentID) cannot hold the contents of \(id)")
                }
            }
            for childID in children { items[childID]?.parentID = parentID }
            items[parentID]?.childrenIDs.replaceSubrange(position...position, with: children)
            items.removeValue(forKey: id)

        case .rename(let id, let title):
            _ = try existing(id)
            items[id]?.title = title

        case .setSavedPage(let id, let url, let title):
            guard case .tab = try existing(id).data else { throw .invalidHierarchy("\(id) is not a tab") }
            items[id]?.data = .tab(SidebarTab(savedURL: url, savedTitle: title))

        case .setFolderExpanded(let id, let isExpanded):
            guard case .folder = try existing(id).data else { throw .invalidHierarchy("\(id) is not a folder") }
            items[id]?.data = .folder(SidebarFolder(isExpanded: isExpanded))

        case .setSplitOrientation(let id, let orientation):
            guard case .split = try existing(id).data else { throw .invalidHierarchy("\(id) is not a split") }
            items[id]?.data = .split(SidebarSplit(orientation: orientation))

        case .insertSpace(let id, let title, let index):
            guard space(id) == nil else { throw .spaceAlreadyExists(id) }
            let position = index ?? spaces.count
            guard (0...spaces.count).contains(position) else { throw .invalidIndex(position) }
            let pinned = SidebarItem(data: .container(SidebarContainer(kind: .pinned)))
            let unpinned = SidebarItem(data: .container(SidebarContainer(kind: .unpinned)))
            items[pinned.id] = pinned
            items[unpinned.id] = unpinned
            spaces.insert(
                SidebarSpace(id: id, title: title, pinnedContainerID: pinned.id, unpinnedContainerID: unpinned.id),
                at: position)

        case .deleteSpace(let id):
            guard let position = spaces.firstIndex(where: { $0.id == id }) else { throw .spaceNotFound(id) }
            guard spaces.count > 1 else { throw .lastSpace }
            let removed = spaces.remove(at: position)
            removeSubtree(removed.pinnedContainerID)
            removeSubtree(removed.unpinnedContainerID)
            if activeSpaceID == id { activeSpaceID = spaces[min(position, spaces.count - 1)].id }

        case .moveSpace(let id, let index):
            guard let position = spaces.firstIndex(where: { $0.id == id }) else { throw .spaceNotFound(id) }
            guard (0..<spaces.count).contains(index) else { throw .invalidIndex(index) }
            spaces.insert(spaces.remove(at: position), at: index)

        case .renameSpace(let id, let title):
            guard let position = spaces.firstIndex(where: { $0.id == id }) else { throw .spaceNotFound(id) }
            spaces[position].title = title

        case .setActiveSpace(let id):
            guard space(id) != nil else { throw .spaceNotFound(id) }
            activeSpaceID = id

        case .setActiveTab(let id):
            if let id, try !existing(id).data.isTab { throw .invalidHierarchy("\(id) is not a tab") }
            activeTabID = id
        }
    }

    private func existing(_ id: SidebarItemID) throws(SidebarStoreError) -> SidebarItem {
        guard let item = items[id] else { throw .itemNotFound(id) }
        return item
    }

    private mutating func insertChild(_ id: SidebarItemID, into parentID: SidebarItemID, at index: Int?)
        throws(SidebarStoreError)
    {
        let count = items[parentID]?.childrenIDs.count ?? 0
        let position = index ?? count
        guard (0...count).contains(position) else { throw .invalidIndex(position) }
        items[parentID]?.childrenIDs.insert(id, at: position)
    }

    /// Removes an item and its descendants from `items`, leaving the parent's child list to the caller.
    private mutating func removeSubtree(_ id: SidebarItemID) {
        var pending = [id]
        var seen: Set<SidebarItemID> = []
        while let next = pending.popLast() {
            guard seen.insert(next).inserted, let item = items.removeValue(forKey: next) else { continue }
            if activeTabID == next { activeTabID = nil }
            pending.append(contentsOf: item.childrenIDs)
        }
    }
}
