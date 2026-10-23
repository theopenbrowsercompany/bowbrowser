import Foundation

public enum SidebarProfileIDKind {}
/// Names the browser profile (cookies, logins, history) a Space shows. Many Spaces may share one profile.
public typealias SidebarProfileID = SidebarID<SidebarProfileIDKind>

extension SidebarID where Kind == SidebarProfileIDKind {
    /// The profile every Space uses until the profiles feature lets the person pick another.
    public static var `default`: SidebarProfileID { "default" }
}

/// Which section of a Space a tab goes into.
public enum SpaceSection: String, Codable, Sendable {
    case pinned
    case unpinned
}

/// Which way a swipe or shortcut moves between Spaces.
public enum SpaceDirection: Sendable {
    case previous
    case next
}

// MARK: Reading Spaces

extension SidebarGraph {
    /// The most Spaces a number shortcut (Ctrl+1 to Ctrl+9) can reach.
    public static let spaceShortcutLimit = 9

    /// The Space on screen.
    public var activeSpace: SidebarSpace? { activeSpaceID.flatMap { space($0) } }

    /// The Space whose pinned or unpinned section holds `id`, or nil for Favorites, a section itself or an unknown ID.
    public func spaceID(containing id: SidebarItemID) -> SidebarSpaceID? {
        var current: SidebarItemID? = id
        var steps = 0
        while let next = current, let item = items[next], steps <= items.count {
            if item.parentID == nil {
                return spaces.first { $0.pinnedContainerID == next || $0.unpinnedContainerID == next }?.id
            }
            current = item.parentID
            steps += 1
        }
        return nil
    }

    /// The tabs a Space shows, in sidebar order: the pinned section, then the unpinned one, with tabs inside folders and
    /// splits included. Tabs of other Spaces never appear.
    public func tabIDs(in spaceID: SidebarSpaceID) -> [SidebarItemID] {
        guard let space = space(spaceID) else { return [] }
        var result: [SidebarItemID] = []
        var seen: Set<SidebarItemID> = []
        func visit(_ id: SidebarItemID) {
            guard let item = items[id], seen.insert(id).inserted else { return }
            if item.data.isTab { result.append(id) }
            item.childrenIDs.forEach(visit)
        }
        visit(space.pinnedContainerID)
        visit(space.unpinnedContainerID)
        return result
    }

    /// The Space for a number shortcut: 1 is the first Space. Nil when there is no such Space, so the shortcut does
    /// nothing.
    public func spaceID(shortcutNumber number: Int) -> SidebarSpaceID? {
        guard (1...Self.spaceShortcutLimit).contains(number), number <= spaces.count else { return nil }
        return spaces[number - 1].id
    }

    /// The Space before or after `current` (default: the active one). Swiping stops at the first and last Space instead
    /// of wrapping around, so this is nil at either end.
    public func adjacentSpaceID(_ direction: SpaceDirection, from current: SidebarSpaceID? = nil) -> SidebarSpaceID? {
        guard let current = current ?? activeSpaceID, let position = spaces.firstIndex(where: { $0.id == current })
        else { return nil }
        let target = direction == .next ? position + 1 : position - 1
        return spaces.indices.contains(target) ? spaces[target].id : nil
    }

    /// The tab a Space should select when it comes on screen: the one it had selected when it was left, if that tab is
    /// still in it or a Favorite it still shows, otherwise its first tab, otherwise none.
    func tabToSelect(in spaceID: SidebarSpaceID) -> SidebarItemID? {
        if let remembered = space(spaceID)?.lastSelectedTabID, items[remembered]?.data.isTab == true,
            self.spaceID(containing: remembered) == spaceID || isInFavorites(remembered, shownBy: spaceID)
        {
            return remembered
        }
        return tabIDs(in: spaceID).first
    }

    /// Whether the selected tab is one the active Space shows: its own tab, or a Favorite of its profile.
    private var selectedTabBelongsOnScreen: Bool {
        guard let tab = activeTabID else { return true }
        if let owner = activeSpaceID, isInFavorites(tab, shownBy: owner) { return true }
        return spaceID(containing: tab) == activeSpaceID
    }

    /// Makes `id` the active Space. The tab selected in the Space being left is remembered for when it returns, and the
    /// new Space selects its own remembered tab. A Favorite stays selected across a switch to a Space of the same profile,
    /// which shows the same Favorites. A Favorite selected when the switch goes to a Space of another profile, which
    /// cannot show it, is remembered by the Space being left, as Arc returns each Space to the tab it was on.
    mutating func activateSpace(_ id: SidebarSpaceID) {
        if let outgoing = activeSpaceID, outgoing != id, let tab = activeTabID,
            spaceID(containing: tab) == outgoing || isInFavorites(tab, shownBy: outgoing),
            let position = spaces.firstIndex(where: { $0.id == outgoing })
        {
            spaces[position].lastSelectedTabID = tab
        }
        activeSpaceID = id
        if activeTabID == nil || !selectedTabBelongsOnScreen { activeTabID = tabToSelect(in: id) }
    }

    /// After tabs moved: if the selected tab is no longer on screen, select the active Space's own tab.
    mutating func reconcileSelectedTab() {
        guard !selectedTabBelongsOnScreen, let id = activeSpaceID else { return }
        activeTabID = tabToSelect(in: id)
    }

    /// A Space name as stored: trimmed, and never empty.
    static func validSpaceTitle(_ title: String) throws(SidebarStoreError) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptySpaceTitle }
        return trimmed
    }
}

// MARK: Changing Spaces

extension SidebarStore {
    /// Adds a Space with empty pinned and unpinned sections and, unless `activate` is false, switches to it.
    /// `index` nil puts it last. The title is trimmed and must not be empty; two Spaces may share a title.
    @discardableResult
    public func createSpace(
        title: String,
        profileID: SidebarProfileID = .default,
        at index: Int? = nil,
        activate: Bool = true
    ) throws -> SidebarSpaceID {
        let id = SidebarSpaceID.make()
        try transaction {
            try mutate(.insertSpace(id, title: title, index: index, profileID: profileID))
            if activate { try mutate(.setActiveSpace(id)) }
        }
        return id
    }

    public func renameSpace(_ id: SidebarSpaceID, to title: String) throws {
        try transaction { try mutate(.renameSpace(id, title: title)) }
    }

    /// Deletes a Space with its pinned and unpinned tabs and returns the IDs of the tabs that went with it, so the app
    /// can close their pages. The last Space cannot be deleted. If the deleted Space was on screen, the Space that took
    /// its place (the next one, or the previous one when it was last) comes on screen.
    @discardableResult
    public func deleteSpace(_ id: SidebarSpaceID) throws -> [SidebarItemID] {
        let closing = graph.tabIDs(in: id)
        try transaction { try mutate(.deleteSpace(id)) }
        return closing
    }

    /// Brings a Space on screen. Switching only changes which Space is shown; it never touches the Spaces' tabs.
    public func switchToSpace(_ id: SidebarSpaceID) throws {
        try transaction { try mutate(.setActiveSpace(id)) }
    }

    /// Ctrl+1 to Ctrl+9: switches to the nth Space (1 is the first). Returns that Space, or nil when there is no nth
    /// Space, in which case nothing changes.
    @discardableResult
    public func switchToSpace(shortcutNumber number: Int) throws -> SidebarSpaceID? {
        guard let id = graph.spaceID(shortcutNumber: number) else { return nil }
        try switchToSpace(id)
        return id
    }

    /// Swipe: switches to the previous or next Space. Returns that Space, or nil at the first or last Space, where
    /// the swipe stops and nothing changes (it does not wrap around).
    @discardableResult
    public func switchToAdjacentSpace(_ direction: SpaceDirection) throws -> SidebarSpaceID? {
        guard let id = graph.adjacentSpaceID(direction) else { return nil }
        try switchToSpace(id)
        return id
    }

    /// Moves a tab, folder or split (with everything inside it) into a section of any Space, at `index` (nil appends).
    /// The Space on screen stays on screen; if the selected tab left it, the Space selects its own tab instead.
    public func moveToSpace(
        _ id: SidebarItemID,
        space: SidebarSpaceID,
        section: SpaceSection = .unpinned,
        index: Int? = nil
    ) throws {
        guard let target = graph.space(space) else { throw SidebarStoreError.spaceNotFound(space) }
        let container = section == .pinned ? target.pinnedContainerID : target.unpinnedContainerID
        try transaction {
            try mutate(.move(id, parent: container, index: index))
            try mutate(.reconcileSelectedTab)
        }
    }

    /// Selects a tab, first switching to the Space that holds it. A Favorite is selected without a switch when the
    /// Space on screen shows it; otherwise the first Space of its profile comes on screen.
    public func selectTab(_ id: SidebarItemID) throws {
        try transaction {
            if let graph = transactionGraph {
                if let owner = graph.spaceID(containing: id) {
                    try mutate(.setActiveSpace(owner))
                } else if let profile = graph.favoritesProfileID(containing: id),
                    graph.activeSpace?.profileID != profile,
                    let owner = graph.spaces.first(where: { $0.profileID == profile })
                {
                    try mutate(.setActiveSpace(owner.id))
                } else if let profile = graph.favoritesProfileID(containing: id),
                    graph.activeSpace?.profileID != profile
                {
                    // No Space shows this Favorite, so selecting it would leave an off screen tab selected.
                    throw SidebarStoreError.invalidHierarchy("no space shows the favorites of profile \(profile)")
                }
            }
            try mutate(.setActiveTab(id))
        }
    }
}
