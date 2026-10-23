import Foundation

/// One fix the cleanup pass made. Nothing the person made is deleted: items without a valid place are collected in the
/// "Recently recovered" folder instead.
public enum SidebarRepair: Hashable, Sendable {
    /// Two items in the file shared an ID; the first was kept.
    case droppedDuplicateItem(SidebarItemID)
    /// This many items or Spaces in the file could not be read and were left out; a copy of the file was kept.
    case skippedUnreadableRecords(Int)
    case droppedDuplicateSpace(SidebarSpaceID)
    case createdSpace(SidebarSpaceID)
    case createdContainer(SidebarItemID, kind: SidebarContainer.Kind)
    /// A section no Space owns was removed; its contents were recovered.
    case removedUnusedContainer(SidebarItemID)
    case droppedMissingChild(parent: SidebarItemID, child: SidebarItemID)
    case droppedDuplicateChild(parent: SidebarItemID, child: SidebarItemID)
    /// A parent listed a child that belongs elsewhere (or cannot be held there), so the listing was removed.
    case droppedMisplacedChild(parent: SidebarItemID, child: SidebarItemID)
    /// A child's `parentID` disagreed with the only valid parent listing it, so it was corrected.
    case fixedParentID(SidebarItemID, parent: SidebarItemID)
    /// A child pointed at a valid parent that did not list it, so it was added to the end of that parent's list.
    case reattachedChild(SidebarItemID, parent: SidebarItemID)
    /// A loop of items that only pointed at each other was opened at this item.
    case brokeCycle(SidebarItemID)
    case createdRecoveredFolder(SidebarItemID)
    /// The item had no valid place and was moved into the "Recently recovered" folder.
    case recovered(SidebarItemID)
    /// The active Space was missing or gone, so the first Space became active.
    case resetActiveSpace(SidebarSpaceID)
    case clearedActiveTab
    /// A split view with no tabs was removed.
    case removedEmptySplit(SidebarItemID)
    /// A split view left with one tab turned back into that plain tab, in the split's place.
    case dissolvedSingleTabSplit(SidebarItemID, tab: SidebarItemID)
    /// A split view held more than four tabs; this one moved out to sit after the split.
    case movedExtraSplitPane(SidebarItemID, from: SidebarItemID)
    /// A split view's width factors or focused pane did not fit its tabs, so they were reset.
    case fixedSplitLayout(SidebarItemID)
}

extension SidebarGraph {
    /// Restores the sidebar's rules: every section exists and has one owner, every child's `parentID` and its parent's
    /// `childrenIDs` agree, loops are opened, and items with no valid place go into "Recently recovered".
    /// Afterwards `integrityProblems()` is empty. Returns what changed, empty when the graph was already sound.
    @discardableResult
    public mutating func repair() -> [SidebarRepair] {
        var log: [SidebarRepair] = []
        normalizeKeys(&log)
        // Taken before sections are repaired, so items recovered from a removed section keep their order.
        let listingOrder = listingOrder()
        repairRoots(&log)
        var orphans = repairParents(listingOrder: listingOrder, &log)
        orphans += breakCycles(excluding: orphans, &log)
        repairActivePointers(&log)
        // An orphaned split with no tabs holds nothing, so it goes before it can be the only thing "Recovered" holds.
        orphans.removeAll { id in
            guard case .split? = items[id]?.data, items[id]?.childrenIDs.isEmpty == true else { return false }
            items[id] = nil
            log.append(.removedEmptySplit(id))
            return true
        }
        placeOrphans(orphans, &log)
        repairSplits(&log)
        return log
    }

    // MARK: Steps

    /// Makes every item stored under its own ID.
    private mutating func normalizeKeys(_ log: inout [SidebarRepair]) {
        guard items.contains(where: { $0.key != $0.value.id }) else { return }
        var normalized: [SidebarItemID: SidebarItem] = [:]
        // Items stored under their own ID win over copies stored under another key.
        for (key, item) in items.sorted(by: { $0.key < $1.key }) where key == item.id { normalized[key] = item }
        for (key, item) in items.sorted(by: { $0.key < $1.key }) where key != item.id {
            if normalized[item.id] == nil {
                normalized[item.id] = item
            } else {
                log.append(.droppedDuplicateItem(item.id))
            }
        }
        items = normalized
    }

    /// Ensures Favorites and every Space have their own containers of the right kind, and removes the rest.
    private mutating func repairRoots(_ log: inout [SidebarRepair]) {
        var claimed: Set<SidebarItemID> = []
        func claim(_ id: SidebarItemID, kind: SidebarContainer.Kind) -> SidebarItemID {
            if case .container(let container)? = items[id]?.data, container.kind == kind, !claimed.contains(id) {
                claimed.insert(id)
                return id
            }
            let container = SidebarItem(data: .container(SidebarContainer(kind: kind)))
            items[container.id] = container
            claimed.insert(container.id)
            log.append(.createdContainer(container.id, kind: kind))
            return container.id
        }

        // Favorites: the default profile always has a section, and so does every profile a Space uses. A profile with
        // no Space keeps its section, because its Favorites are the person's even while no Space shows them.
        var seenSpaces: Set<SidebarSpaceID> = []
        spaces = spaces.filter { space in
            if seenSpaces.insert(space.id).inserted { return true }
            log.append(.droppedDuplicateSpace(space.id))
            return false
        }
        if spaces.isEmpty {
            let space = SidebarSpace(
                id: .make(), title: Self.defaultSpaceTitle, pinnedContainerID: .make(), unpinnedContainerID: .make())
            spaces = [space]
            log.append(.createdSpace(space.id))
        }
        let favoriteProfiles = Set(favoritesContainerIDs.keys).union(spaces.map(\.profileID)).union([.default])
        for profile in Self.defaultFirst(favoriteProfiles) {
            favoritesContainerIDs[profile] = claim(favoritesContainerIDs[profile] ?? .make(), kind: .favorites)
        }
        for index in spaces.indices {
            spaces[index].pinnedContainerID = claim(spaces[index].pinnedContainerID, kind: .pinned)
            spaces[index].unpinnedContainerID = claim(spaces[index].unpinnedContainerID, kind: .unpinned)
        }

        for item in items.values.sorted(by: { $0.id < $1.id }) where item.data.isContainer {
            if !claimed.contains(item.id) {
                items[item.id] = nil
                log.append(.removedUnusedContainer(item.id))
            } else if item.parentID != nil {
                items[item.id]?.parentID = nil
            }
        }
    }

    /// Picks one parent for every item and rebuilds the child lists to match. Returns the items with no valid parent,
    /// in a stable order that follows where they used to be listed.
    private mutating func repairParents(listingOrder: [SidebarItemID: Int], _ log: inout [SidebarRepair])
        -> [SidebarItemID]
    {
        let sortedIDs = items.keys.sorted()
        var listedBy: [SidebarItemID: [SidebarItemID]] = [:]
        for parentID in sortedIDs {
            for childID in items[parentID]?.childrenIDs ?? [] where !(listedBy[childID]?.contains(parentID) ?? false) {
                listedBy[childID, default: []].append(parentID)
            }
        }

        func canParent(_ parentID: SidebarItemID?, _ child: SidebarItem) -> Bool {
            guard let parentID, parentID != child.id, let parent = items[parentID] else { return false }
            return parent.data.canHold(child.data)
        }

        var chosen: [SidebarItemID: SidebarItemID] = [:]
        var appended: [SidebarItemID: [SidebarItemID]] = [:]
        var orphans: [SidebarItemID] = []
        for id in sortedIDs {
            guard let item = items[id], !item.data.isContainer else { continue }
            let listers = listedBy[id] ?? []
            if canParent(item.parentID, item), let parentID = item.parentID, listers.contains(parentID) {
                chosen[id] = parentID
            } else if let parentID = listers.first(where: { canParent($0, item) }) {
                chosen[id] = parentID
                log.append(.fixedParentID(id, parent: parentID))
            } else if canParent(item.parentID, item), let parentID = item.parentID {
                chosen[id] = parentID
                appended[parentID, default: []].append(id)
                log.append(.reattachedChild(id, parent: parentID))
            } else {
                orphans.append(id)
            }
        }

        for parentID in items.keys.sorted() {
            guard let parent = items[parentID] else { continue }
            var seen: Set<SidebarItemID> = []
            var children: [SidebarItemID] = []
            for childID in parent.childrenIDs {
                if items[childID] == nil {
                    log.append(.droppedMissingChild(parent: parentID, child: childID))
                } else if chosen[childID] != parentID {
                    log.append(.droppedMisplacedChild(parent: parentID, child: childID))
                } else if !seen.insert(childID).inserted {
                    log.append(.droppedDuplicateChild(parent: parentID, child: childID))
                } else {
                    children.append(childID)
                }
            }
            children += appended[parentID] ?? []
            items[parentID]?.childrenIDs = children
            items[parentID]?.parentID = chosen[parentID]
        }

        return orphans.sorted { (listingOrder[$0] ?? .max, $0) < (listingOrder[$1] ?? .max, $1) }
    }

    /// Finds items that cannot be reached from any section (only loops remain after `repairParents`) and opens each
    /// loop by detaching one of its items. Returns the detached items.
    private mutating func breakCycles(excluding orphans: [SidebarItemID], _ log: inout [SidebarRepair])
        -> [SidebarItemID]
    {
        var detached: [SidebarItemID] = []
        while true {
            let reachable = reachableIDs(from: rootIDs + orphans + detached)
            guard let start = items.keys.sorted().first(where: { !reachable.contains($0) }) else { break }
            // Walk up from the unreachable item until an item repeats: that item is on the loop.
            var path: Set<SidebarItemID> = []
            var current = start
            while path.insert(current).inserted, let parentID = items[current]?.parentID {
                current = parentID
            }
            if let parentID = items[current]?.parentID { items[parentID]?.childrenIDs.removeAll { $0 == current } }
            items[current]?.parentID = nil
            detached.append(current)
            log.append(.brokeCycle(current))
        }
        return detached
    }

    /// Puts orphans at the end of the "Recently recovered" folder, creating the folder at the top of the active Space's
    /// pinned section when needed.
    private mutating func placeOrphans(_ orphans: [SidebarItemID], _ log: inout [SidebarRepair]) {
        guard !orphans.isEmpty else { return }
        let targetSpace = activeSpaceID.flatMap { space($0) } ?? spaces[0]  // Set by repairActivePointers.
        let section = targetSpace.pinnedContainerID
        var remaining = orphans

        let folderID: SidebarItemID
        if case .folder? = items[.recentlyRecovered]?.data {
            folderID = .recentlyRecovered
            let reachable = reachableIDs(from: rootIDs)
            if let position = remaining.firstIndex(of: folderID) {
                // The folder itself was an orphan: give it a place first.
                remaining.remove(at: position)
                attach(folderID, to: section, at: 0)
            } else if !reachable.contains(folderID) {
                // The folder sits inside an orphan; lift it out so it cannot end up inside itself.
                if let parentID = items[folderID]?.parentID {
                    items[parentID]?.childrenIDs.removeAll { $0 == folderID }
                }
                attach(folderID, to: section, at: 0)
            }
        } else {
            let id: SidebarItemID = items[.recentlyRecovered] == nil ? .recentlyRecovered : .make()
            items[id] = SidebarItem(id: id, title: Self.recentlyRecoveredTitle, data: .folder(SidebarFolder()))
            attach(id, to: section, at: 0)
            log.append(.createdRecoveredFolder(id))
            folderID = id
        }

        for id in remaining {
            attach(id, to: folderID, at: nil)
            log.append(.recovered(id))
        }
    }

    private mutating func repairActivePointers(_ log: inout [SidebarRepair]) {
        if activeSpaceID.flatMap({ space($0) }) == nil {
            activeSpaceID = spaces[0].id
            log.append(.resetActiveSpace(spaces[0].id))
        }
        if let activeTabID, items[activeTabID]?.data.isTab != true {
            self.activeTabID = nil
            log.append(.clearedActiveTab)
        }
    }

    // MARK: Helpers

    /// The first place each item is listed, walking the sections in sidebar order and then every other item by ID.
    private func listingOrder() -> [SidebarItemID: Int] {
        var order: [SidebarItemID: Int] = [:]
        for parentID in rootIDs + items.keys.sorted() {
            for childID in items[parentID]?.childrenIDs ?? [] where order[childID] == nil {
                order[childID] = order.count
            }
        }
        return order
    }

    private mutating func attach(_ id: SidebarItemID, to parentID: SidebarItemID, at index: Int?) {
        items[id]?.parentID = parentID
        if let index {
            items[parentID]?.childrenIDs.insert(id, at: index)
        } else {
            items[parentID]?.childrenIDs.append(id)
        }
    }

    private func reachableIDs(from starts: [SidebarItemID]) -> Set<SidebarItemID> {
        var reachable: Set<SidebarItemID> = []
        var pending = starts
        while let next = pending.popLast() {
            guard items[next] != nil, reachable.insert(next).inserted else { continue }
            pending.append(contentsOf: items[next]?.childrenIDs ?? [])
        }
        return reachable
    }
}
