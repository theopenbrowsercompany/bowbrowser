import AppKit
import BowCore

// The design area's Favorites surface: the grid and its first tile, in the sidebar's outline.

extension E2EAppAdapter {
    static func favoritesLook(of controller: BrowserWindowController) -> E2EDesignFavoritesLook {
        let outline = controller.e2eSidebar.outlineView
        func inOutline(_ view: NSView?) -> CGRect { view.map { outline.convert($0.bounds, from: $0) } ?? .zero }
        let grid = views(in: outline, FavoritesGridView.self).first
        return E2EDesignFavoritesLook(
            tileFrame: inOutline(grid?.tiles.first), gridFrame: inOutline(grid), tileCount: grid?.tiles.count ?? 0)
    }
}
