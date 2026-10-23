import Foundation

// Split views: two to four tabs shown side by side, saved as one sidebar item. The split item's children are the tabs
// in pane order; the item itself records the orientation, each pane's width factor and the focused pane. This file
// holds the rules and the operations the window needs: create a split from tabs, add or remove a pane, resize, move
// focus, reorder panes and separate the split back into plain tabs.
//
// A split always holds two to four tabs. Closing a pane that leaves one tab turns the split back into that plain tab
// (the person asked for two views side by side; one is just a tab), and the cleanup pass applies the same rule to a
// file that holds a split with one tab. A split with no tabs is removed, since it holds nothing the person made.

extension SidebarSplit {
    public static let minimumPanes = 2
    public static let maximumPanes = 4
    /// The smallest share a pane keeps when a divider is dragged or the factors are set.
    public static let minimumPaneFraction = 0.1

    /// The factors scaled to sum to 1, or nil when there are none or one is not a positive, finite number.
    public static func normalized(_ factors: [Double]) -> [Double]? {
        guard !factors.isEmpty, factors.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let total = factors.reduce(0, +)
        guard total.isFinite, total > 0 else { return nil }
        return factors.map { $0 / total }
    }

    /// Fractions summing to 1 where none is under `minimumPaneFraction`: panes below it are raised to it and the
    /// others give up the difference in proportion to what they hold above it.
    static func keepingMinimum(_ fractions: [Double]) -> [Double] {
        let minimum = minimumPaneFraction
        guard Double(fractions.count) * minimum <= 1 else { return fractions }
        var result = fractions
        var raised: Set<Int> = []
        while true {
            let low = result.indices.filter { !raised.contains($0) && result[$0] < minimum - 1e-12 }
            if low.isEmpty { break }
            raised.formUnion(low)
            for index in low { result[index] = minimum }
            let free = result.indices.filter { !raised.contains($0) }
            guard !free.isEmpty else { break }
            let budget = 1 - minimum * Double(raised.count)
            let held = free.reduce(0) { $0 + result[$1] }
            for index in free { result[index] = held > 0 ? result[index] * budget / held : budget / Double(free.count) }
        }
        return result
    }
}

// MARK: Reading splits

extension SidebarGraph {
    /// The split data of `id`, or nil when it is not a split.
    public func split(_ id: SidebarItemID) -> SidebarSplit? {
        if case .split(let split)? = items[id]?.data { return split }
        return nil
    }

    /// The tabs of a split in pane order. Empty for anything that is not a split.
    public func splitPaneIDs(_ id: SidebarItemID) -> [SidebarItemID] {
        guard split(id) != nil else { return [] }
        return children(of: id).filter { $0.data.isTab }.map(\.id)
    }

    /// The split whose panes include `tab`, if any.
    public func splitID(containing tab: SidebarItemID) -> SidebarItemID? {
        guard items[tab]?.data.isTab == true, let parentID = items[tab]?.parentID, split(parentID) != nil
        else { return nil }
        return parentID
    }

    /// Each pane's share of the split, in pane order, summing to 1. Equal shares when none are saved or the saved ones
    /// do not fit the panes (for example right after a tab joined or left through a generic move).
    public func splitWidthFractions(_ id: SidebarItemID) -> [Double] {
        let count = splitPaneIDs(id).count
        guard count > 0 else { return [] }
        if let saved = split(id)?.widthFactors, saved.count == count, let normalized = SidebarSplit.normalized(saved) {
            return normalized
        }
        return Array(repeating: 1 / Double(count), count: count)
    }

    /// The pane that has focus: the saved one when it is still a pane, otherwise the first.
    public func focusedSplitPaneID(_ id: SidebarItemID) -> SidebarItemID? {
        let panes = splitPaneIDs(id)
        if let saved = split(id)?.focusedItemID, panes.contains(saved) { return saved }
        return panes.first
    }

    /// The saved focus when it is still a pane, otherwise nil (so a stale focus never blocks a layout change).
    fileprivate func savedPaneFocus(_ id: SidebarItemID) -> SidebarItemID? {
        guard let saved = split(id)?.focusedItemID, splitPaneIDs(id).contains(saved) else { return nil }
        return saved
    }

    /// The factors to write back when only something else about the layout changes: the saved ones when they fit,
    /// otherwise empty (equal panes).
    fileprivate func fittingWidthFactors(_ id: SidebarItemID) -> [Double] {
        let saved = split(id)?.widthFactors ?? []
        return saved.count == splitPaneIDs(id).count ? saved : []
    }

    /// The section (Favorites, pinned or unpinned container) an item hangs under.
    fileprivate func sectionID(of id: SidebarItemID) -> SidebarItemID? {
        var current = id
        var steps = 0
        while let parentID = items[current]?.parentID, steps <= items.count {
            current = parentID
            steps += 1
        }
        return items[current]?.data.isContainer == true ? current : nil
    }

    // MARK: Rules used by mutations

    /// Refuses a change that would put a fifth tab into a split.
    func requireSplitRoom(in parentID: SidebarItemID, excluding childID: SidebarItemID) throws(SidebarStoreError) {
        guard split(parentID) != nil, let parent = items[parentID] else { return }
        guard parent.childrenIDs.filter({ $0 != childID }).count < SidebarSplit.maximumPanes else {
            throw .invalidHierarchy("a split view holds at most \(SidebarSplit.maximumPanes) tabs")
        }
    }

    /// Sets a split's width factors (normalized; empty keeps panes equal) and focused pane.
    mutating func setSplitLayout(_ id: SidebarItemID, widthFactors: [Double], focusedItemID: SidebarItemID?)
        throws(SidebarStoreError)
    {
        guard let item = items[id] else { throw .itemNotFound(id) }
        guard case .split(var split) = item.data else { throw .invalidHierarchy("\(id) is not a split") }
        var factors: [Double] = []
        if !widthFactors.isEmpty {
            guard widthFactors.count == item.childrenIDs.count, let normalized = SidebarSplit.normalized(widthFactors)
            else {
                throw .invalidHierarchy(
                    "width factors must be positive, one for each of the \(item.childrenIDs.count) panes")
            }
            factors = normalized
        }
        if let focusedItemID, !item.childrenIDs.contains(focusedItemID) {
            throw .invalidHierarchy("\(focusedItemID) is not a pane of \(id)")
        }
        split.widthFactors = factors
        split.focusedItemID = focusedItemID
        items[id]?.data = .split(split)
    }

    // MARK: Cleanup

    /// Applies the split rules to a graph whose links are already sound: a split with no tabs is removed, a split with
    /// one tab turns back into that tab in the split's place, tabs beyond the fourth move out to sit after the split,
    /// and width factors or a focused pane that do not fit the tabs are reset.
    ///
    /// A child that is not a tab (a damaged file's folder inside a split) leaves the split the same way an extra pane
    /// does, so the pane count is the count of tabs, as `integrityProblems()` counts them. With `previous`, the
    /// committed graph, a split that lost panes since then keeps the widths of the panes that stayed.
    mutating func repairSplits(_ log: inout [SidebarRepair], previous: SidebarGraph? = nil) {
        for id in items.keys.sorted() {
            guard case .split(var split)? = items[id]?.data, let item = items[id],
                let parentID = item.parentID, let position = items[parentID]?.childrenIDs.firstIndex(of: id)
            else { continue }
            var panes = item.childrenIDs.filter { items[$0]?.data.isTab == true }
            var extras = item.childrenIDs.filter { items[$0] != nil && items[$0]?.data.isTab != true }
            if panes.count > SidebarSplit.maximumPanes {
                extras += panes[SidebarSplit.maximumPanes...]
                panes.removeSubrange(SidebarSplit.maximumPanes...)
            }
            let widthsBefore = split.widthFactors

            if !extras.isEmpty {
                items[parentID]?.childrenIDs.insert(contentsOf: extras, at: position + 1)
                for extra in extras {
                    items[extra]?.parentID = parentID
                    log.append(.movedExtraSplitPane(extra, from: id))
                }
                items[id]?.childrenIDs = panes
            }

            switch panes.count {
            case 0:
                items[parentID]?.childrenIDs.remove(at: position)
                items[id] = nil
                log.append(.removedEmptySplit(id))
                continue
            case 1:
                items[parentID]?.childrenIDs[position] = panes[0]
                items[panes[0]]?.parentID = parentID
                items[id] = nil
                log.append(.dissolvedSingleTabSplit(id, tab: panes[0]))
                continue
            default:
                break
            }

            // Panes that left since the last commit take their share with them; the rest keep their proportions.
            if let before = previous?.splitPaneIDs(id), widthsBefore.count == before.count, before.count > panes.count {
                let kept = panes.compactMap { before.firstIndex(of: $0) }
                if kept.count == panes.count, let normalized = SidebarSplit.normalized(kept.map { widthsBefore[$0] }) {
                    split.widthFactors = normalized
                    items[id]?.data = .split(split)
                }
            }

            var fixed = false
            if !split.widthFactors.isEmpty {
                if split.widthFactors.count == panes.count, let normalized = SidebarSplit.normalized(split.widthFactors)
                {
                    if zip(normalized, split.widthFactors).contains(where: { abs($0 - $1) > 1e-9 }) {
                        split.widthFactors = normalized
                        fixed = true
                    }
                } else {
                    split.widthFactors = []
                    fixed = true
                }
            }
            if let focused = split.focusedItemID, !panes.contains(focused) {
                split.focusedItemID = nil
                fixed = true
            }
            if fixed {
                items[id]?.data = .split(split)
                log.append(.fixedSplitLayout(id))
            }
        }
    }
}

// MARK: Changing splits

extension SidebarStore {
    /// Makes a split view of two to four tabs, saved as one item that takes the place of `tabs[0]` among its siblings.
    /// The tabs join it in the order given, with equal widths, and `focusing` (default the first tab) has focus.
    ///
    /// Refused, changing nothing, when there are fewer than two or more than four tabs, a tab is listed twice, is
    /// already in a split or is a Favorite, or the tabs are not all in the same section (so a tab never becomes pinned
    /// or unpinned by joining a split).
    @discardableResult
    public func createSplit(
        from tabs: [SidebarItemID],
        orientation: SidebarSplit.Orientation = .horizontal,
        focusing focused: SidebarItemID? = nil,
        id: SidebarItemID = .make()
    ) throws -> SidebarItemID {
        let graph = self.graph
        guard (SidebarSplit.minimumPanes...SidebarSplit.maximumPanes).contains(tabs.count) else {
            throw SidebarStoreError.invalidHierarchy(
                "a split view needs \(SidebarSplit.minimumPanes) to \(SidebarSplit.maximumPanes) tabs, not \(tabs.count)"
            )
        }
        guard Set(tabs).count == tabs.count else {
            throw SidebarStoreError.invalidHierarchy("a tab cannot be in a split twice")
        }
        for tab in tabs { try requireSplittable(tab, in: graph) }
        guard Set(tabs.map { graph.sectionID(of: $0) }).count == 1 else {
            throw SidebarStoreError.invalidHierarchy("the tabs of a split view must be in the same section")
        }
        if let focused, !tabs.contains(focused) {
            throw SidebarStoreError.invalidHierarchy("\(focused) is not one of the tabs")
        }
        guard let first = tabs.first, let parentID = graph[first]?.parentID,
            let position = graph[parentID]?.childrenIDs.firstIndex(of: first)
        else { throw SidebarStoreError.invalidHierarchy("\(tabs[0]) has no place for a split") }

        try transaction {
            try mutate(.insert(.split(id: id, orientation: orientation), parent: parentID, index: position))
            for tab in tabs { try mutate(.move(tab, parent: id)) }
            try mutate(
                .setSplitLayout(
                    id, widthFactors: Array(repeating: 1, count: tabs.count), focusedItemID: focused ?? first))
        }
        return id
    }

    /// Adds a tab to a split as a pane at `index` (nil appends). The new pane takes an equal share and the others
    /// shrink to make room; focus stays where it was.
    /// Refused when the split already has four panes, or the tab is in a split, is a Favorite or is in another section.
    public func addPane(_ tab: SidebarItemID, to splitID: SidebarItemID, at index: Int? = nil) throws {
        let graph = self.graph
        try requireSplit(splitID, in: graph)
        try requireSplittable(tab, in: graph)
        guard graph.sectionID(of: tab) == graph.sectionID(of: splitID) else {
            throw SidebarStoreError.invalidHierarchy("\(tab) is in another section than the split view")
        }
        let count = graph.splitPaneIDs(splitID).count
        guard count < SidebarSplit.maximumPanes else {
            throw SidebarStoreError.invalidHierarchy("a split view holds at most \(SidebarSplit.maximumPanes) tabs")
        }
        let position = index ?? count
        guard (0...count).contains(position) else { throw SidebarStoreError.invalidIndex(position) }

        let share = 1 / Double(count + 1)
        var factors = graph.splitWidthFractions(splitID).map { $0 * (1 - share) }
        factors.insert(share, at: position)
        factors = SidebarSplit.keepingMinimum(factors)
        let focused = graph.savedPaneFocus(splitID)
        try transaction {
            try mutate(.move(tab, parent: splitID, index: position))
            try mutate(.setSplitLayout(splitID, widthFactors: factors, focusedItemID: focused))
        }
    }

    /// Takes a pane out of its split. With `closing` the tab is deleted (the pane's tab was closed); otherwise it
    /// becomes a plain tab right after the split. The remaining panes share the freed width, and if the pane that had
    /// focus leaves, its neighbour gets it. When fewer than two panes remain the split turns back into plain tabs.
    /// Returns whether the split still exists.
    @discardableResult
    public func removePane(_ tab: SidebarItemID, closing: Bool = false) throws -> Bool {
        let graph = self.graph
        guard let splitID = graph.splitID(containing: tab) else {
            throw SidebarStoreError.invalidHierarchy("\(tab) is not a pane of a split view")
        }
        let panes = graph.splitPaneIDs(splitID)
        guard let paneIndex = panes.firstIndex(of: tab), let parentID = graph[splitID]?.parentID,
            let position = graph[parentID]?.childrenIDs.firstIndex(of: splitID)
        else { throw SidebarStoreError.invalidHierarchy("\(splitID) has no place in the sidebar") }

        var remaining = panes
        remaining.remove(at: paneIndex)
        var factors = graph.splitWidthFractions(splitID)
        factors.remove(at: paneIndex)
        let savedFocus = graph.savedPaneFocus(splitID)
        let focused: SidebarItemID? =
            savedFocus == tab ? (remaining.isEmpty ? nil : remaining[max(paneIndex - 1, 0)]) : savedFocus

        try transaction {
            if closing {
                try mutate(.delete(tab))
            } else {
                try mutate(.move(tab, parent: parentID, index: position + 1))
            }
            if remaining.count >= SidebarSplit.minimumPanes {
                try mutate(.setSplitLayout(splitID, widthFactors: factors, focusedItemID: focused))
            } else {
                try dissolveSplit(splitID)
            }
            if closing { try mutate(.reconcileSelectedTab) }
        }
        return self.graph[splitID] != nil
    }

    /// Separates a split back into its tabs, which take the split's place in their order. Returns the tabs.
    @discardableResult
    public func separateSplit(_ splitID: SidebarItemID) throws -> [SidebarItemID] {
        let graph = self.graph
        try requireSplit(splitID, in: graph)
        let panes = graph.splitPaneIDs(splitID)
        try transaction { try dissolveSplit(splitID) }
        return panes
    }

    /// Gives focus to a pane of its split.
    public func setFocusedPane(_ tab: SidebarItemID) throws {
        let graph = self.graph
        guard let splitID = graph.splitID(containing: tab) else {
            throw SidebarStoreError.invalidHierarchy("\(tab) is not a pane of a split view")
        }
        try transaction {
            try mutate(
                .setSplitLayout(splitID, widthFactors: graph.fittingWidthFactors(splitID), focusedItemID: tab))
        }
    }

    public func setSplitOrientation(_ splitID: SidebarItemID, _ orientation: SidebarSplit.Orientation) throws {
        try requireSplit(splitID, in: graph)
        try transaction { try mutate(.setSplitOrientation(splitID, orientation)) }
    }

    /// Sets every pane's width factor at once, in pane order. The factors are normalized to sum to 1.
    /// Refused when there is not one factor per pane, one is not a positive number, or a pane would get less than
    /// `SidebarSplit.minimumPaneFraction` of the split.
    public func setSplitWidthFactors(_ splitID: SidebarItemID, _ factors: [Double]) throws {
        let graph = self.graph
        try requireSplit(splitID, in: graph)
        guard factors.count == graph.splitPaneIDs(splitID).count, let normalized = SidebarSplit.normalized(factors),
            normalized.allSatisfy({ $0 >= SidebarSplit.minimumPaneFraction - 1e-9 })
        else {
            throw SidebarStoreError.invalidHierarchy(
                "width factors need one positive number per pane, none under \(SidebarSplit.minimumPaneFraction) of the total"
            )
        }
        let focused = graph.savedPaneFocus(splitID)
        try transaction { try mutate(.setSplitLayout(splitID, widthFactors: normalized, focusedItemID: focused)) }
    }

    /// Moves the divider after pane `dividerIndex` so the panes before it take `position` (0 to 1) of the split's
    /// length in total. Only the two panes beside the divider change, and each keeps at least the minimum share, so a
    /// drag past that stops there.
    public func moveSplitDivider(_ splitID: SidebarItemID, dividerIndex: Int, to position: Double) throws {
        let graph = self.graph
        try requireSplit(splitID, in: graph)
        let fractions = graph.splitWidthFractions(splitID)
        guard (0..<max(fractions.count - 1, 0)).contains(dividerIndex), position.isFinite else {
            throw SidebarStoreError.invalidIndex(dividerIndex)
        }
        let before = fractions[..<dividerIndex].reduce(0, +)
        let end = before + fractions[dividerIndex] + fractions[dividerIndex + 1]
        let lower = before + SidebarSplit.minimumPaneFraction
        let upper = end - SidebarSplit.minimumPaneFraction
        guard lower <= upper else { return }
        let divider = min(max(position, lower), upper)
        var factors = fractions
        factors[dividerIndex] = divider - before
        factors[dividerIndex + 1] = end - divider
        let focused = graph.savedPaneFocus(splitID)
        try transaction { try mutate(.setSplitLayout(splitID, widthFactors: factors, focusedItemID: focused)) }
    }

    /// Moves a pane to `index` among the panes (counted after it leaves its place), carrying its width with it.
    public func movePane(_ tab: SidebarItemID, to index: Int) throws {
        let graph = self.graph
        guard let splitID = graph.splitID(containing: tab),
            let from = graph.splitPaneIDs(splitID).firstIndex(of: tab)
        else { throw SidebarStoreError.invalidHierarchy("\(tab) is not a pane of a split view") }
        let count = graph.splitPaneIDs(splitID).count
        guard (0..<count).contains(index) else { throw SidebarStoreError.invalidIndex(index) }
        var factors = graph.splitWidthFractions(splitID)
        factors.insert(factors.remove(at: from), at: index)
        let focused = graph.savedPaneFocus(splitID)
        try transaction {
            try mutate(.move(tab, parent: splitID, index: index))
            try mutate(.setSplitLayout(splitID, widthFactors: factors, focusedItemID: focused))
        }
    }

    // MARK: Helpers

    /// Moves a split's tabs to its place among its siblings, in order, and deletes the split. Runs inside a
    /// transaction.
    private func dissolveSplit(_ splitID: SidebarItemID) throws {
        guard let graph = transactionGraph, let parentID = graph[splitID]?.parentID,
            let position = graph[parentID]?.childrenIDs.firstIndex(of: splitID)
        else { throw SidebarStoreError.invalidHierarchy("\(splitID) has no place in the sidebar") }
        for (offset, child) in graph.children(of: splitID).enumerated() {
            try mutate(.move(child.id, parent: parentID, index: position + offset))
        }
        try mutate(.delete(splitID))
    }

    private func requireSplit(_ id: SidebarItemID, in graph: SidebarGraph) throws {
        guard let item = graph[id] else { throw SidebarStoreError.itemNotFound(id) }
        guard case .split = item.data else { throw SidebarStoreError.invalidHierarchy("\(id) is not a split view") }
    }

    private func requireSplittable(_ id: SidebarItemID, in graph: SidebarGraph) throws {
        guard let item = graph[id] else { throw SidebarStoreError.itemNotFound(id) }
        guard item.data.isTab else { throw SidebarStoreError.invalidHierarchy("\(id) is not a tab") }
        guard graph.splitID(containing: id) == nil else {
            throw SidebarStoreError.invalidHierarchy("\(id) is already in a split view")
        }
        guard !graph.isInFavorites(id) else {
            throw SidebarStoreError.invalidHierarchy("\(id) is a Favorite, which cannot join a split view")
        }
    }
}
