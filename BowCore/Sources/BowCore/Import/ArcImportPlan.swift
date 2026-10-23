import Foundation

/// How the person wants Arc's Spaces brought in. The three choices copy Dia's import menu.
public enum ArcSpaceImportMode: String, CaseIterable, Equatable, Sendable {
    /// No Spaces and no pinned tabs. Only Favorites of Arc's default profile come across.
    case skipSpaces
    /// Every chosen Arc Space becomes a Space with a profile of its own. Bow has no profile management yet, so each
    /// one gets a distinct new profile ID, and a copy of the Favorites of the Arc profile it belonged to.
    case spacesAsProfiles
    /// Arc Spaces become Bow Spaces. Spaces that shared an Arc profile share one Bow profile and its Favorites.
    case arcSpaces
}

/// What the person chose in the import wizard. Building a preview or applying a plan never changes the Arc file.
public struct ArcImportPlan: Equatable, Sendable {
    public var mode: ArcSpaceImportMode
    /// The Arc Space ids to bring, one per checkbox. Nil brings every Space. Ignored when Spaces are skipped.
    public var selectedSpaceIDs: Set<String>?
    /// Whether Favorites come along. They come with the Spaces that show them (see `ArcSpaceImportMode`).
    public var includeFavorites: Bool
    /// Whether each Space's unpinned tabs come along. Off by default: Arc's unpinned tabs are short lived.
    public var includeUnpinnedTabs: Bool
    /// Whether items the importer rescued from Arc's orphans (see `ArcImportOptions.OrphanPolicy.collect`) come
    /// along, as one folder in the first imported Space.
    public var includeRecoveredItems: Bool

    public init(
        mode: ArcSpaceImportMode = .arcSpaces,
        selectedSpaceIDs: Set<String>? = nil,
        includeFavorites: Bool = true,
        includeUnpinnedTabs: Bool = false,
        includeRecoveredItems: Bool = true
    ) {
        self.mode = mode
        self.selectedSpaceIDs = selectedSpaceIDs
        self.includeFavorites = includeFavorites
        self.includeUnpinnedTabs = includeUnpinnedTabs
        self.includeRecoveredItems = includeRecoveredItems
    }
}

/// The Bow profile an imported Space or Favorites list lands in.
public enum ArcImportProfileTarget: Hashable, Sendable {
    /// Bow's default profile.
    case defaultProfile
    /// A profile named after an Arc profile; every import of that Arc profile lands in it.
    case arcProfile(SidebarProfileID)
    /// A profile created for this one Space, with a new ID when the import is applied.
    case separateProfile

    static func mapping(_ profile: ArcImportProfile) -> ArcImportProfileTarget {
        switch profile {
        case .default: .defaultProfile
        case .custom(let basename): .arcProfile(SidebarProfileID("arc-\(basename)"))
        }
    }
}
