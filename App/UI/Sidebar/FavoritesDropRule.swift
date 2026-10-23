import BowCore

/// Favorites are not a drag target or source yet. The Favorites grid brings its own drops: it replaces this rule's
/// file and its line in `SidebarDropValidators.all` (`SidebarDropRuleList.swift`) with its own.
enum FavoritesDropValidator: SidebarDropValidator {
    static func validate(_ drop: SidebarDrop, in graph: SidebarGraph) -> SidebarDropVerdict {
        graph.isInFavorites(drop.parent) || graph.isInFavorites(drop.item) ? .refuse : .abstain
    }
}
