import BowCore
import Foundation

/// A sidebar item dropped (or about to be dropped) somewhere in the outline.
struct SidebarDrop: Equatable, Sendable {
    /// The item being dragged: a tab, folder or split.
    var item: SidebarItemID
    /// The container, folder or split it lands in.
    var parent: SidebarItemID
    /// Its place among `parent`'s children, counted before it leaves its own place (the outline's drop gap).
    var index: Int

    /// The index the store's move wants, counted after the item has left its own place.
    func storeIndex(in graph: SidebarGraph) -> Int {
        guard graph[item]?.parentID == parent, let from = graph[parent]?.childrenIDs.firstIndex(of: item), from < index
        else { return index }
        return index - 1
    }
}

/// What a validator says about a drop.
enum SidebarDropVerdict: Equatable, Sendable {
    /// The validator has no rule for this drop.
    case abstain
    /// The drop must not happen; the outline shows no drop gap there.
    case refuse
}

/// One rule about where sidebar items may be dropped.
///
/// Extension point: a new rule (dragging into Favorites, into a split) is one new file with a type conforming to
/// this protocol plus one line in `SidebarDropValidators.all` (`SidebarDropRuleList.swift`). A drop goes through
/// when no validator refuses it; the store's own rules (what a parent can hold, commit-time repair of splits) still
/// apply when it is made.
@MainActor
protocol SidebarDropValidator {
    static func validate(_ drop: SidebarDrop, in graph: SidebarGraph) -> SidebarDropVerdict
}

extension SidebarDropValidators {
    /// Whether `drop` may happen: no validator refuses it.
    static func allows(_ drop: SidebarDrop, in graph: SidebarGraph) -> Bool {
        all.allSatisfy { $0.validate(drop, in: graph) != .refuse }
    }
}

/// The sidebar's shape: only tabs, folders and splits move, into a parent that can hold them, never into themselves,
/// and within the Space on screen.
enum StructureDropValidator: SidebarDropValidator {
    static func validate(_ drop: SidebarDrop, in graph: SidebarGraph) -> SidebarDropVerdict {
        guard let item = graph[drop.item], let parent = graph[drop.parent], !item.data.isContainer,
            parent.data.canHold(item.data), !graph.isDescendant(drop.parent, of: drop.item),
            (0...parent.childrenIDs.count).contains(drop.index)
        else { return .refuse }
        if let space = graph.activeSpaceID, graph.spaceID(containing: drop.parent) != space,
            !graph.isInFavorites(drop.parent)
        {
            return .refuse
        }
        return .abstain
    }
}

/// A split's tabs stay together: a tab inside a split moves only with its split, apart from reordering within it,
/// and no tab joins a split by a drag (making a split is its own action).
enum SplitTabDropValidator: SidebarDropValidator {
    static func validate(_ drop: SidebarDrop, in graph: SidebarGraph) -> SidebarDropVerdict {
        let from = graph[drop.item]?.parentID
        let leavesSplit = from.map { if case .split? = graph[$0]?.data { true } else { false } } ?? false
        let entersSplit = if case .split? = graph[drop.parent]?.data { true } else { false }
        guard leavesSplit || entersSplit else { return .abstain }
        return from == drop.parent ? .abstain : .refuse
    }
}

extension SidebarDrop {
    /// Makes the drop through the store, in the Space on screen. A tab crossing the divider is pinned or unpinned:
    /// a tab dropped into the pinned zone from today has its live page made its saved address, and a pinned tab
    /// dropped into today keeps its live page as its saved page. A folder or split crossing the divider does the
    /// same for every loaded tab inside it. Anything else only moves. Returns whether the store took it.
    @MainActor
    @discardableResult
    func perform(in context: any SidebarActionContext) -> Bool {
        let graph = context.graph
        guard SidebarDropValidators.allows(self, in: graph), let space = graph.activeSpace,
            let isTab = graph[item]?.data.isTab
        else { return false }
        let index = storeIndex(in: graph)
        // Dropped where it already is: nothing to save or redraw.
        if graph[item]?.parentID == parent, graph[parent]?.childrenIDs.firstIndex(of: item) == index { return true }
        let wasPinned = graph.isDescendant(item, of: space.pinnedContainerID)
        let toPinned = graph.isDescendant(parent, of: space.pinnedContainerID)
        let crosses = wasPinned != toPinned
        return context.changeSidebar { store in
            if isTab, crosses, toPinned, parent == space.pinnedContainerID {
                try store.pinTab(item, page: context.livePage(of: item), at: index)
            } else if isTab, crosses, !toPinned, parent == space.unpinnedContainerID {
                try store.unpinTab(item, page: context.livePage(of: item), at: index)
            } else {
                // A move within a zone, into a folder of the other zone, or of a whole folder or split.
                let crossing = crosses ? Self.tabs(under: item, in: graph) : []
                try store.transaction {
                    for tab in crossing {
                        guard let page = context.livePage(of: tab) else { continue }
                        try store.mutate(.setSavedPage(tab, url: page.url.absoluteString, title: page.title))
                    }
                    try store.mutate(.move(item, parent: parent, index: index))
                    try store.mutate(.reconcileSelectedTab)
                }
            }
        }
    }

    /// `id` when it is a tab, else the tabs anywhere inside it.
    private static func tabs(under id: SidebarItemID, in graph: SidebarGraph) -> [SidebarItemID] {
        guard let item = graph[id] else { return [] }
        if item.data.isTab { return [id] }
        return item.childrenIDs.flatMap { tabs(under: $0, in: graph) }
    }
}
