import AppKit
import BowCore

// The Favorites area of the adapter: E2EFavoritesApp over the window's FavoritesGridView, the header view of the
// sidebar's Favorites section.

extension E2ETestApp: E2EFavoritesApp {
    func favoriteTiles(of page: any E2EPage) throws -> [E2EFavoriteTile] {
        try adapter.requireActive(token, "read the Favorites grid")
        return try adapter.favoriteTiles(of: page)
    }

    func favoritesGridHeight(of page: any E2EPage) throws -> (row: Double, lastTileBottom: Double) {
        try adapter.requireActive(token, "read the Favorites grid")
        return try adapter.favoritesGridHeight(of: page)
    }

    func dragToFavorites(_ page: any E2EPage, at index: Int) throws {
        try adapter.requireActive(token, "drag a tab onto the Favorites grid")
        try adapter.dragToFavorites(page, at: index)
    }

    func clickFavorite(_ page: any E2EPage) throws {
        try adapter.requireActive(token, "click a Favorite")
        try adapter.clickFavorite(page)
    }

    func clickFavorite(titled title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click a Favorite")
        try adapter.clickFavorite(titled: title, in: page)
    }

    func activeTab(of page: any E2EPage) throws -> E2EActiveTab {
        let controller = try E2EAppAdapter.tabPage(page).controller
        let list = controller.tabList
        let shown = list.activeID.flatMap(controller.engineTab(for:)).map { tab in
            controller.selectedTab === tab
        }
        return E2EActiveTab(
            title: list.activeTab?.title ?? "", url: list.activeTab?.url?.absoluteString ?? "",
            isShown: shown ?? false, loadedCount: controller.tabs.count)
    }

    func favoriteMenu(of page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read a Favorite's menu")
        return try adapter.favoriteMenuItems(of: page).map(\.title)
    }

    func chooseFavoriteMenuItem(_ title: String, of page: any E2EPage) throws {
        try adapter.requireActive(token, "choose a Favorite's menu item")
        let items = try adapter.favoriteMenuItems(of: page)
        guard let item = items.first(where: { $0.title == title }), item.isEnabled, let action = item.action,
            NSApp.sendAction(action, to: item.target, from: item)
        else {
            throw E2EError("no menu item \"\(title)\" in \(items.map(\.title).joined(separator: " | "))")
        }
    }
}

extension E2EAppAdapter {
    /// The Favorites grid of `page`'s window, laid out.
    static func favoritesGrid(of page: any E2EPage) throws -> FavoritesGridView {
        let sidebar = try tabPage(page).controller.e2eSidebar
        guard let row = sidebar.rowKinds().firstIndex(where: { $0.section?.zone == .favorites }),
            let grid = sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? FavoritesGridView
        else { throw E2EError("the sidebar shows no Favorites grid") }
        grid.layoutSubtreeIfNeeded()
        return grid
    }

    /// The tile of `page`'s tab in its window's grid.
    private static func favoriteTile(of page: any E2EPage) throws -> (FavoritesGridView, FavoriteTileView) {
        let grid = try favoritesGrid(of: page)
        let item = try sidebarItem(of: try tabPage(page))
        guard let tile = grid.tiles.first(where: { $0.item == item }) else {
            throw E2EError("the tab is not a Favorite in its window's grid")
        }
        return (grid, tile)
    }

    func favoriteTiles(of page: any E2EPage) throws -> [E2EFavoriteTile] {
        try Self.favoritesGrid(of: page).tiles.map {
            E2EFavoriteTile(
                title: $0.title, hasIcon: $0.hasIcon, letter: $0.letterField.stringValue, isActive: $0.isActive)
        }
    }

    func favoritesGridHeight(of page: any E2EPage) throws -> (row: Double, lastTileBottom: Double) {
        let grid = try Self.favoritesGrid(of: page)
        return (Double(grid.frame.height), Double(grid.tiles.last?.frame.maxY ?? 0))
    }

    func dragToFavorites(_ page: any E2EPage, at index: Int) throws {
        let grid = try Self.favoritesGrid(of: page)
        let item = try Self.sidebarItem(of: try Self.tabPage(page))
        // A point just inside the gap: the left edge of the tile at `index`, or the right edge of the last tile.
        let point: NSPoint
        if grid.tiles.isEmpty {
            point = NSPoint(x: grid.bounds.midX, y: grid.bounds.midY)
        } else if grid.tiles.indices.contains(index) {
            let frame = grid.tiles[index].frame
            point = NSPoint(x: frame.minX + 2, y: frame.midY)
        } else {
            let frame = grid.tiles[grid.tiles.count - 1].frame
            point = NSPoint(x: frame.maxX - 2, y: frame.midY)
        }
        let gap = grid.gap(at: point)
        guard gap == index || (index > grid.tiles.count && gap == grid.tiles.count) else {
            throw E2EError("the point for gap \(index) resolved to gap \(gap)")
        }
        guard grid.drop(item, at: gap) else { throw E2EError("the Favorites grid refused the drop at \(gap)") }
    }

    func clickFavorite(_ page: any E2EPage) throws {
        let (grid, tile) = try Self.favoriteTile(of: page)
        guard grid.click(tile.item) else { throw E2EError("clicking the Favorite opened or showed nothing") }
    }

    func clickFavorite(titled title: String, in page: any E2EPage) throws {
        let grid = try Self.favoritesGrid(of: page)
        guard let tile = grid.tiles.first(where: { $0.title == title }) else {
            throw E2EError("no Favorite titled \(title) in [\(grid.tiles.map(\.title).joined(separator: ","))]")
        }
        guard grid.click(tile.item) else { throw E2EError("clicking the Favorite showed nothing") }
    }

    func favoriteMenuItems(of page: any E2EPage) throws -> [NSMenuItem] {
        let (grid, tile) = try Self.favoriteTile(of: page)
        return grid.menuItems(for: tile.item)
    }
}
