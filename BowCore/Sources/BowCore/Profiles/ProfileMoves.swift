import Foundation

// Moving tabs between Spaces and into or out of Favorites when the two sides may show different profiles, and which
// profiles the person may delete.

extension SidebarGraph {
    /// The profile whose storage item `id` uses: the profile of the Space holding it, or of the Favorites holding it.
    /// Nil for an item that is in neither (a container, or an unknown ID).
    public func profileID(holding id: SidebarItemID) -> SidebarProfileID? {
        if let owner = spaceID(containing: id) { return space(owner)?.profileID }
        return favoritesProfileID(containing: id)
    }

    /// Whether putting item `id` into the Favorites of `profile` would carry it from another profile's storage.
    /// IDs match ignoring case, as the engine matches folders. An item in no Space or Favorites crosses nothing.
    public func crossesProfiles(_ id: SidebarItemID, intoFavoritesOf profile: SidebarProfileID) -> Bool {
        guard let source = profileID(holding: id) else { return false }
        return TabMoveKind.between(source, profile) != .keepsLivePage
    }

    /// The Spaces tab `id` can be moved to with "Move to Space": every Space but the one holding it, in sidebar order.
    /// Empty for a Favorite (it leaves Favorites through "Remove from Favorites"), a folder, a split or an unknown ID.
    public func spaceMoveTargets(for id: SidebarItemID) -> [SidebarSpace] {
        guard self[id]?.data.isTab == true, let owner = spaceID(containing: id) else { return [] }
        return spaces.filter { $0.id != owner }
    }

    /// What moving tab `id` to Space `target` means for its page: it keeps its live page when both Spaces show one
    /// profile, and otherwise must load again in the target's profile after the person agrees. Nil when the move is
    /// not one "Move to Space" makes: `id` is not a tab of a Space, `target` is unknown, or it is the tab's own Space.
    public func tabMoveKind(of id: SidebarItemID, to target: SidebarSpaceID) -> TabMoveKind? {
        guard spaceMoveTargets(for: id).contains(where: { $0.id == target }), let source = spaceID(containing: id)
        else { return nil }
        return tabMoveKind(from: source, to: target)
    }

    /// Whether dropping sidebar item `id` on the footer icon of Space `target` moves it there: exactly when "Move to
    /// Space" offers that Space for it. A folder, a split, a Favorite, an unknown item or Space, and the Space already
    /// holding the tab (the one on screen) are refused.
    public func acceptsDrop(of id: SidebarItemID, onSpace target: SidebarSpaceID) -> Bool {
        tabMoveKind(of: id, to: target) != nil
    }
}

extension SidebarStore {
    /// "Move to Space": moves tab `id` to the top of the same section (pinned or today) of Space `target`. Whether the
    /// page can follow is the app's to decide first (`SidebarGraph.tabMoveKind(of:to:)`); the store only moves the row.
    /// The Space on screen stays on screen, and selects its own tab if the moved one was selected.
    public func moveTab(_ id: SidebarItemID, toSpace target: SidebarSpaceID) throws {
        guard graph.tabMoveKind(of: id, to: target) != nil else {
            if graph.space(target) == nil { throw SidebarStoreError.spaceNotFound(target) }
            throw SidebarStoreError.invalidHierarchy("\(id) is not a tab of another space than \(target)")
        }
        try moveToSpace(id, space: target, section: graph.isPinned(id) ? .pinned : .unpinned, index: 0)
    }
}

extension ProfileRegistry {
    /// The profiles the person may delete now, in the registry's order: every profile but the default that none of
    /// `spaceProfiles` (the profile IDs the Spaces show, matched ignoring case) points at.
    public func deletableProfiles(spaceProfiles: some Sequence<SidebarProfileID>) -> [ProfileRecord] {
        let shown = Set(spaceProfiles.map { $0.rawValue.lowercased() })
        return profiles.filter { !$0.isDefault && !shown.contains($0.id.rawValue.lowercased()) }
    }
}
