import Foundation

// Favorites: the icon row at the top of the sidebar. Each profile has one Favorites section, and every Space of that
// profile shows it. A Favorite is a tab with a saved address, exactly like a pinned tab, and the section holds only
// tabs (no folders or splits).

extension SidebarGraph {
    /// Profiles that have a Favorites section: the default profile first, then the others by ID.
    var favoritesProfileIDs: [SidebarProfileID] { Self.defaultFirst(favoritesContainerIDs.keys) }

    static func defaultFirst(_ profiles: some Sequence<SidebarProfileID>) -> [SidebarProfileID] {
        let sorted = profiles.sorted()
        return sorted.filter { $0 == .default } + sorted.filter { $0 != .default }
    }

    /// The Favorites section of a profile, or nil when the profile has none yet (every profile a Space uses has one).
    public func favoritesContainerID(for profile: SidebarProfileID) -> SidebarItemID? { favoritesContainerIDs[profile] }

    /// The profile whose Favorites section holds `id`, or nil when `id` is not in any Favorites.
    public func favoritesProfileID(containing id: SidebarItemID) -> SidebarProfileID? {
        favoritesProfileIDs.first { profile in
            favoritesContainerIDs[profile].map { isDescendant(id, of: $0) } ?? false
        }
    }

    /// Whether `id` is a Favorite, or the Favorites section itself, of any profile. Archiving and auto closing skip
    /// these items.
    public func isInFavorites(_ id: SidebarItemID) -> Bool { favoritesProfileID(containing: id) != nil }

    /// Whether `id` is in the Favorites that the Space `space` shows (its profile's).
    public func isInFavorites(_ id: SidebarItemID, shownBy space: SidebarSpaceID) -> Bool {
        guard let profile = self.space(space)?.profileID else { return false }
        return favoritesProfileID(containing: id) == profile
    }

    /// The Favorites of a profile in order, as tab IDs. Empty for an unknown profile.
    public func favoriteIDs(for profile: SidebarProfileID) -> [SidebarItemID] {
        favoritesContainerIDs[profile].map { children(of: $0).map(\.id) } ?? []
    }

    /// The Favorites the Space on screen shows.
    public var activeFavoriteIDs: [SidebarItemID] {
        favoriteIDs(for: activeSpace?.profileID ?? .default)
    }
}

// MARK: Changing Favorites

extension SidebarStore {
    /// Adds a new Favorite with this saved address and title at `index` (nil appends). `profile` defaults to the
    /// profile of the Space on screen. Returns the new tab's ID.
    @discardableResult
    public func addFavorite(
        url: String,
        title: String = "",
        profile: SidebarProfileID? = nil,
        at index: Int? = nil
    ) throws -> SidebarItemID {
        let item = SidebarItem.tab(url: url, title: title)
        try transaction {
            let container = try favoritesContainer(for: profile)
            try mutate(.insert(item, parent: container, index: index))
        }
        return item.id
    }

    /// Makes an existing tab a Favorite (dragging a tab into the icon row), at `index` (nil appends).
    ///
    /// `page` is the address and title the Favorite will return to, normally the page the tab shows now; without it the
    /// tab keeps the address it was saved with. A tab already in this profile's Favorites is only moved, so this also
    /// reorders. Folders and splits are refused: Favorites hold tabs only.
    public func moveToFavorites(
        _ id: SidebarItemID,
        profile: SidebarProfileID? = nil,
        at index: Int? = nil,
        page: (url: String, title: String)? = nil
    ) throws {
        try transaction {
            let container = try favoritesContainer(for: profile)
            try mutate(.move(id, parent: container, index: index))
            if let page { try mutate(.setSavedPage(id, url: page.url, title: page.title)) }
            try mutate(.reconcileSelectedTab)
        }
    }

    /// Moves a Favorite to another position in its row. `index` is counted after it leaves its old place, so it is
    /// where the Favorite ends up.
    public func reorderFavorite(_ id: SidebarItemID, to index: Int) throws {
        guard let profile = graph.favoritesProfileID(containing: id),
            let container = graph.favoritesContainerIDs[profile]
        else { throw SidebarStoreError.invalidHierarchy("\(id) is not a favorite") }
        try transaction { try mutate(.move(id, parent: container, index: index)) }
    }

    /// Takes a Favorite out of the icon row and keeps it as a tab: it goes to the top of the unpinned or pinned section of
    /// `space` (default: the Space on screen). Nothing is closed, and a selected Favorite stays selected.
    public func removeFavorite(
        _ id: SidebarItemID,
        to section: SpaceSection = .unpinned,
        in space: SidebarSpaceID? = nil,
        at index: Int? = 0
    ) throws {
        guard graph.isInFavorites(id), graph.items[id]?.data.isTab == true else {
            throw SidebarStoreError.invalidHierarchy("\(id) is not a favorite")
        }
        guard let target = space ?? graph.activeSpaceID else { throw SidebarStoreError.invalidHierarchy("no space") }
        guard let destination = graph.space(target) else { throw SidebarStoreError.spaceNotFound(target) }
        let container = section == .pinned ? destination.pinnedContainerID : destination.unpinnedContainerID
        try transaction {
            try mutate(.move(id, parent: container, index: index))
            try mutate(.reconcileSelectedTab)
        }
    }

    /// Deletes a Favorite for good. It must be in Favorites; the app closes its page.
    public func deleteFavorite(_ id: SidebarItemID) throws {
        guard graph.isInFavorites(id), graph.items[id]?.data.isTab == true else {
            throw SidebarStoreError.invalidHierarchy("\(id) is not a favorite")
        }
        try transaction { try mutate(.delete(id)) }
    }

    private func favoritesContainer(for profile: SidebarProfileID?) throws -> SidebarItemID {
        let graph = transactionGraph ?? graph
        let resolved = profile ?? graph.activeSpace?.profileID ?? .default
        guard let container = graph.favoritesContainerIDs[resolved] else {
            throw SidebarStoreError.invalidHierarchy("profile \(resolved) has no favorites")
        }
        return container
    }
}
