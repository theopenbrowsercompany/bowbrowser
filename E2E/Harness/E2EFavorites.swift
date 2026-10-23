import Foundation

/// One tile of the Favorites grid, as the grid draws it.
struct E2EFavoriteTile: Equatable, CustomStringConvertible {
    var title: String
    /// True while the tile shows a site icon rather than its letter tile.
    var hasIcon: Bool
    /// The letter the letter tile shows.
    var letter: String
    /// True while the tile is highlighted as showing the active tab.
    var isActive: Bool

    var description: String { "\(title)\(isActive ? "*" : "")\(hasIcon ? " icon" : " letter=\(letter)")" }
}

/// The window's active tab as a test sees it, for a Favorite that may have no page of its own.
struct E2EActiveTab: Equatable, CustomStringConvertible {
    var title: String
    var url: String
    /// True while the active tab has a page and the window shows it.
    var isShown: Bool
    /// How many pages the window has loaded (its Space's tabs and its Favorites).
    var loadedCount: Int

    var description: String { "\(title)(\(url))\(isShown ? " shown" : " unloaded") loaded=\(loadedCount)" }
}

/// The Favorites grid at the top of the sidebar as a test sees it. Each action goes through the grid's own handling
/// of the control a person uses: its drop handling for a drag onto it, its click handling for a tile, and the tile's
/// context menu.
@MainActor
protocol E2EFavoritesApp: E2EZonesApp {
    /// The tiles of the Favorites grid of `page`'s window, in grid order.
    func favoriteTiles(of page: any E2EPage) throws -> [E2EFavoriteTile]
    /// The height of the grid's header row in the outline of `page`'s window, and the bottom of its last tile.
    func favoritesGridHeight(of page: any E2EPage) throws -> (row: Double, lastTileBottom: Double)
    /// Drags `page`'s tab (a tab or a Favorite) onto the grid of its window at gap `index` (counted before it leaves
    /// its place): the grid resolves the gap at the point between those tiles and drops there. Throws when the grid
    /// refuses.
    func dragToFavorites(_ page: any E2EPage, at index: Int) throws
    /// Clicks the tile of `page`'s tab, a Favorite of its window's grid.
    func clickFavorite(_ page: any E2EPage) throws
    /// Clicks the tile titled `title` in the grid of `page`'s window, for a Favorite whose page has closed.
    func clickFavorite(titled title: String, in page: any E2EPage) throws
    /// The active tab of `page`'s window, as the window lists it.
    func activeTab(of page: any E2EPage) throws -> E2EActiveTab
    /// The titles of the context menu of `page`'s tile, a Favorite of its window's grid.
    func favoriteMenu(of page: any E2EPage) throws -> [String]
    /// Chooses the item titled `title` in the context menu of `page`'s tile.
    func chooseFavoriteMenuItem(_ title: String, of page: any E2EPage) throws
}
