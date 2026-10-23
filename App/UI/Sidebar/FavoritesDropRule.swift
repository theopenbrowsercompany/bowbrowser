import BowCore

/// Where Favorites may be dragged, as in Arc: a tab may be dropped into the Favorites the Space on screen shows (its
/// profile's), up to `limit` of them, and a Favorite of those may be dragged within them or out to the Space's pinned
/// or today zone. Folders and splits never go in, nothing moves into or out of another profile's Favorites, and a tab
/// of a Space on another profile never goes in.
enum FavoritesDropValidator: SidebarDropValidator {
    /// The most Favorites one profile holds (Arc's limit).
    static let limit = 12

    static func validate(_ drop: SidebarDrop, in graph: SidebarGraph) -> SidebarDropVerdict {
        let intoFavorites = graph.isInFavorites(drop.parent)
        let fromFavorites = graph.isInFavorites(drop.item)
        guard intoFavorites || fromFavorites else { return .abstain }
        guard let space = graph.activeSpace, let shown = graph.favoritesContainerID(for: space.profileID) else {
            return .refuse
        }
        if fromFavorites, graph[drop.item]?.parentID != shown { return .refuse }
        guard intoFavorites else { return .abstain }
        guard drop.parent == shown, graph[drop.item]?.data.isTab == true,
            !graph.crossesProfiles(drop.item, intoFavoritesOf: space.profileID)
        else { return .refuse }
        let count = graph[shown]?.childrenIDs.count ?? 0
        return fromFavorites || count < limit ? .abstain : .refuse
    }
}
