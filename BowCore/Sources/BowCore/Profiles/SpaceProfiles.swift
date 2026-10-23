import Foundation

/// One entry of a Space's "Profile" menu: a profile the Space can show, and whether it shows it now.
public struct SpaceProfileChoice: Equatable, Sendable {
    public var id: SidebarProfileID
    public var name: String
    public var isCurrent: Bool

    public init(id: SidebarProfileID, name: String, isCurrent: Bool) {
        self.id = id
        self.name = name
        self.isCurrent = isCurrent
    }
}

extension ProfileRegistry {
    /// The profiles a Space on `current` can choose from, in the registry's order (the default first), with the
    /// current one marked. IDs match ignoring case, as the engine matches folders. A Space on a profile the registry
    /// does not know has no entry marked.
    public func choices(current: SidebarProfileID) -> [SpaceProfileChoice] {
        let key = current.rawValue.lowercased()
        return profiles.map { profile in
            SpaceProfileChoice(id: profile.id, name: profile.name, isCurrent: profile.id.rawValue.lowercased() == key)
        }
    }
}

/// What pointing a Space at another profile means for its tabs.
public enum SpaceProfileChange: Equatable, Sendable {
    /// The Space already shows that profile (IDs match ignoring case): nothing changes and no page reloads.
    case unchanged
    /// The Space moves to the other profile. Each of `tabs` (the Space's pinned and today tabs, Favorites aside,
    /// since they belong to a profile and not a Space) that has a live page loads its address again in the new
    /// profile, because a page cannot carry its logins and storage from one profile to another.
    case reload(tabs: [SidebarItemID])
}

extension SidebarGraph {
    /// What pointing Space `space` at `profile` means, or nil when the Space is unknown.
    public func spaceProfileChange(_ space: SidebarSpaceID, to profile: SidebarProfileID) -> SpaceProfileChange? {
        guard let current = self.space(space) else { return nil }
        if current.profileID.rawValue.lowercased() == profile.rawValue.lowercased() { return .unchanged }
        return .reload(tabs: tabIDs(in: space))
    }
}

extension SidebarStore {
    /// Points Space `id` at `profile` and returns the tabs whose pages must load again there (none when the Space
    /// already shows it, in which case nothing is written). The new profile's Favorites show in place of the old
    /// one's; a Favorite of the old profile that was selected gives way to the Space's own tab.
    @discardableResult
    public func setSpaceProfile(_ id: SidebarSpaceID, to profile: SidebarProfileID) throws -> [SidebarItemID] {
        guard let change = graph.spaceProfileChange(id, to: profile) else { throw SidebarStoreError.spaceNotFound(id) }
        guard case .reload(let tabs) = change else { return [] }
        try transaction { try mutate(.setSpaceProfile(id, profile)) }
        return tabs
    }
}
