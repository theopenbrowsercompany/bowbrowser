import Foundation

/// The whole sidebar as a flat graph of items keyed by ID, plus the Spaces that own its sections.
///
/// The roots are containers: one for Favorites and two per Space (pinned and unpinned). Every other item hangs under a
/// container, folder or split. A graph read from disk may break these rules; `repair()` restores them, and the store
/// only commits graphs that pass `integrityProblems()`.
public struct SidebarGraph: Hashable, Sendable {
    public internal(set) var items: [SidebarItemID: SidebarItem]
    /// Spaces in the order the person arranged them.
    public internal(set) var spaces: [SidebarSpace]
    public internal(set) var favoritesContainerID: SidebarItemID
    /// The Space on screen. Always set in a sound graph; optional only so a damaged file can still be read.
    public internal(set) var activeSpaceID: SidebarSpaceID?
    /// The tab that was selected when the sidebar was last saved; the only one that loads right away on launch.
    public internal(set) var activeTabID: SidebarItemID?

    /// Builds a graph from raw parts without checking them. Run `repair()` before trusting it.
    public init(
        items: [SidebarItemID: SidebarItem],
        spaces: [SidebarSpace],
        favoritesContainerID: SidebarItemID,
        activeSpaceID: SidebarSpaceID? = nil,
        activeTabID: SidebarItemID? = nil
    ) {
        self.items = items
        self.spaces = spaces
        self.favoritesContainerID = favoritesContainerID
        self.activeSpaceID = activeSpaceID
        self.activeTabID = activeTabID
    }

    /// The default title of the Space a fresh sidebar starts with.
    public static let defaultSpaceTitle = "Space"
    /// The title of the folder the cleanup pass collects orphans in.
    public static let recentlyRecoveredTitle = "Recently recovered"

    /// An empty sidebar: Favorites and one Space with empty pinned and unpinned sections.
    public static func fresh() -> SidebarGraph {
        let favorites = SidebarItem(data: .container(SidebarContainer(kind: .favorites)))
        let pinned = SidebarItem(data: .container(SidebarContainer(kind: .pinned)))
        let unpinned = SidebarItem(data: .container(SidebarContainer(kind: .unpinned)))
        let space = SidebarSpace(
            id: .make(), title: defaultSpaceTitle, pinnedContainerID: pinned.id, unpinnedContainerID: unpinned.id)
        return SidebarGraph(
            items: [favorites.id: favorites, pinned.id: pinned, unpinned.id: unpinned],
            spaces: [space],
            favoritesContainerID: favorites.id,
            activeSpaceID: space.id)
    }

    public subscript(id: SidebarItemID) -> SidebarItem? { items[id] }

    public func space(_ id: SidebarSpaceID) -> SidebarSpace? { spaces.first { $0.id == id } }

    public func children(of id: SidebarItemID) -> [SidebarItem] {
        (items[id]?.childrenIDs ?? []).compactMap { items[$0] }
    }

    /// The containers every visible item hangs under: Favorites, then each Space's pinned and unpinned sections.
    public var rootIDs: [SidebarItemID] {
        [favoritesContainerID] + spaces.flatMap { [$0.pinnedContainerID, $0.unpinnedContainerID] }
    }

    /// Item IDs in sidebar order: each root, then its descendants depth first. Unreachable items are left out.
    public func orderedIDs() -> [SidebarItemID] {
        var result: [SidebarItemID] = []
        var seen: Set<SidebarItemID> = []
        func visit(_ id: SidebarItemID) {
            guard items[id] != nil, seen.insert(id).inserted else { return }
            result.append(id)
            for child in items[id]?.childrenIDs ?? [] { visit(child) }
        }
        for root in rootIDs { visit(root) }
        return result
    }

    /// The number of items that are not containers: tabs, folders and splits.
    public var contentItemCount: Int { items.values.filter { !$0.data.isContainer }.count }

    /// Whether `id` is `ancestor` or sits somewhere below it.
    public func isDescendant(_ id: SidebarItemID, of ancestor: SidebarItemID) -> Bool {
        var current: SidebarItemID? = id
        var steps = 0
        while let next = current, steps <= items.count {
            if next == ancestor { return true }
            current = items[next]?.parentID
            steps += 1
        }
        return false
    }

    /// Every way this graph breaks the sidebar's rules, in plain words. Empty means the graph is sound.
    public func integrityProblems() -> [String] {
        var problems: [String] = []
        for (key, item) in items where key != item.id {
            problems.append("item stored under \(key) has id \(item.id)")
        }

        var owners: [SidebarItemID: String] = [:]
        func checkRoot(_ id: SidebarItemID, kind: SidebarContainer.Kind, owner: String) {
            if let previous = owners[id] {
                problems.append("container \(id) is used by both \(previous) and \(owner)")
            }
            owners[id] = owner
            guard case .container(let container)? = items[id]?.data, container.kind == kind else {
                problems.append("\(owner) has no \(kind.rawValue) container \(id)")
                return
            }
        }
        checkRoot(favoritesContainerID, kind: .favorites, owner: "favorites")
        if spaces.isEmpty { problems.append("there are no spaces") }
        var spaceIDs: Set<SidebarSpaceID> = []
        for space in spaces {
            if !spaceIDs.insert(space.id).inserted { problems.append("space \(space.id) appears twice") }
            checkRoot(space.pinnedContainerID, kind: .pinned, owner: "space \(space.id) pinned")
            checkRoot(space.unpinnedContainerID, kind: .unpinned, owner: "space \(space.id) unpinned")
        }

        for item in items.values.sorted(by: { $0.id < $1.id }) {
            if item.data.isContainer {
                if owners[item.id] == nil { problems.append("container \(item.id) belongs to no space") }
                if item.parentID != nil { problems.append("container \(item.id) has a parent") }
            } else if let parentID = item.parentID, let parent = items[parentID] {
                if !parent.data.canHold(item.data) { problems.append("\(parentID) cannot hold \(item.id)") }
                let listings = parent.childrenIDs.filter { $0 == item.id }.count
                if listings != 1 { problems.append("\(parentID) lists \(item.id) \(listings) times") }
            } else {
                problems.append("\(item.id) has no parent")
            }
            for childID in item.childrenIDs {
                guard let child = items[childID] else {
                    problems.append("\(item.id) lists missing child \(childID)")
                    continue
                }
                if child.parentID != item.id { problems.append("\(item.id) lists \(childID), whose parent differs") }
            }
        }

        let reachable = Set(orderedIDs())
        for id in items.keys.sorted() where !reachable.contains(id) {
            problems.append("\(id) cannot be reached from any section")
        }

        if activeSpaceID.flatMap({ space($0) }) == nil {
            problems.append("active space \(activeSpaceID?.rawValue ?? "none") does not exist")
        }
        if let activeTabID, items[activeTabID]?.data.isTab != true {
            problems.append("active tab \(activeTabID) is not a tab")
        }
        return problems
    }

    /// Which tabs load on launch: only the active tab loads its page right away; every other tab is restored with its
    /// saved address and title and loads when the person selects it.
    public func launchPlan() -> SidebarLaunchPlan {
        let tabs = orderedIDs().filter { items[$0]?.data.isTab == true }
        let active = activeTabID.flatMap { tabs.contains($0) ? $0 : nil }
        return SidebarLaunchPlan(loadNow: active, loadOnSelect: tabs.filter { $0 != active })
    }
}

/// What the app does with saved tabs at launch.
public struct SidebarLaunchPlan: Equatable, Sendable {
    /// The one tab that loads its page right away, if a tab was active.
    public var loadNow: SidebarItemID?
    /// Tabs shown in the sidebar that load only once selected, in sidebar order.
    public var loadOnSelect: [SidebarItemID]
}
