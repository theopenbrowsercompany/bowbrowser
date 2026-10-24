import Foundation

/// The Favorites grid's part of `E2EDesignLook`. Read by E2E/Harness/E2EAppAdapter+DesignFavorites.swift.
struct E2EDesignFavoritesLook {
    /// Frames in the sidebar's outline (top left origin, x from the sidebar's leading edge), zero when not shown: the
    /// first Favorite tile and the whole grid.
    var tileFrame: CGRect
    var gridFrame: CGRect
    /// How many tiles the grid shows.
    var tileCount: Int
}
