import Foundation

/// Tests of the Favorites grid at the top of the sidebar. Uses the sidebar fixtures in E2E/Fixtures/sidebar/.
@MainActor
enum FavoritesTests {
    static let all: [any E2ETest] = [FavoritesGridTest()]
}

/// Opens tabs A, B and C, and drags A then B onto the grid: both leave today and show as tiles with their site icons,
/// in a grid sized to its one row. Drags B before A, clicks B (it opens in today, and a second click shows that tab
/// instead of opening another), drags A out to pinned, and removes B with its menu (it goes to the top of today).
struct FavoritesGridTest: E2ETest {
    let name = "favorites"
    let checks = ["favorites", "favorites.reorder", "favorites.open", "favorites.move-out", "favorites.remove"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EFavoritesApp else { throw E2EError("the app has no Favorites grid") }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
        /// What `read` gives once `condition` holds for it, or what it gave last when the wait's budget (at most 3
        /// seconds of the step's time) runs out, so the check that follows says what it saw.
        func settle<T>(_ read: () throws -> T, until condition: (T) -> Bool) async throws -> T {
            let deadline = Date().addingTimeInterval(E2EWaits.budget(limit: 3))
            var value = try read()
            while !condition(value), Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
                value = try read()
            }
            return value
        }
        /// The grid's tiles in `page`'s window once `condition` holds for them, or as they are when the wait gives up.
        func tiles(of page: any E2EPage, until condition: ([E2EFavoriteTile]) -> Bool) async throws
            -> [E2EFavoriteTile]
        {
            try await settle({ try app.favoriteTiles(of: page) }, until: condition)
        }
        func titles(_ tiles: [E2EFavoriteTile]) -> String { "[\(tiles.map(\.title).joined(separator: ","))]" }

        let a = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: url("A"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let (b, c) = try await run.step("new tabs B and C", timeout: E2ETimeouts.firstLoad) {
            let b = try app.clickNewTab(besides: a, opening: url("B"))
            _ = try await b.waitForLoad(after: 0)
            let c = try app.clickNewTab(besides: a, opening: url("C"))
            _ = try await c.waitForLoad(after: 0)
            // Each row shows its site icon, which the grid keeps when the tab becomes a Favorite.
            try await SidebarWaits.rows(app, of: a) {
                $0.map(\.title) == ["A", "B", "C"] && $0.allSatisfy(\.hasFavicon)
            }
            return (b, c)
        }
        let empty = try app.favoritesGridHeight(of: c).row

        let added = try await run.step("drag A and B onto the grid", timeout: E2ETimeouts.step) {
            try app.dragToFavorites(a, at: 0)
            try app.dragToFavorites(b, at: 1)
            let tiles = try await tiles(of: c) { $0.count == 2 }
            let rows = try await settle({ try app.sidebarRows(of: c) }) { $0.map(\.title) == ["C"] }
            return (tiles: tiles, rows: rows, height: try app.favoritesGridHeight(of: c))
        }
        let icons = added.tiles.filter(\.hasIcon).count
        // Sized to its content: one row of tiles plus the grid's bottom margin, taller than the empty grid.
        let fits = added.height.row == added.height.lastTileBottom + 8 && added.height.row > empty
        run.check(
            name,
            passed: titles(added.tiles) == "[A,B]" && icons == 2 && fits
                && SidebarWaits.summary(added.rows) == "tabs=[C] active=C",
            "items=\(titles(added.tiles)) icons=\(icons) height=\(added.height.row) empty=\(empty) "
                + SidebarWaits.summary(added.rows))

        let reordered = try await run.step("drag B before A", timeout: E2ETimeouts.step) {
            try app.dragToFavorites(b, at: 0)
            return try await tiles(of: c) { titles($0) == "[B,A]" }
        }
        run.check("favorites.reorder", passed: titles(reordered) == "[B,A]", "items=\(titles(reordered))")

        let opened = try await run.step("click B twice", timeout: E2ETimeouts.firstLoad) {
            try app.clickFavorite(b)
            let first = try await settle({ try app.sidebarRows(of: c) }) {
                SidebarWaits.summary($0) == "tabs=[C,B] active=B"
            }
            let lit = try await tiles(of: c) { $0.first?.isActive == true }
            try app.clickSidebarRow(of: c)
            _ = try await settle({ try app.sidebarRows(of: c) }) { SidebarWaits.summary($0) == "tabs=[C,B] active=C" }
            try app.clickFavorite(b)
            let second = try await settle({ try app.sidebarRows(of: c) }) { $0.last?.isActive == true }
            return (first: first, lit: lit.first?.isActive == true, second: second)
        }
        run.check(
            "favorites.open",
            passed: SidebarWaits.summary(opened.first) == "tabs=[C,B] active=B" && opened.lit
                && SidebarWaits.summary(opened.second) == "tabs=[C,B] active=B",
            "first=\(SidebarWaits.summary(opened.first)) tile_active=\(opened.lit) "
                + "second=\(SidebarWaits.summary(opened.second))")

        let movedOut = try await run.step("drag A out to pinned", timeout: E2ETimeouts.step) {
            let outline = try app.sidebarOutline(of: c)
            guard let pinned = outline.firstIndex(of: "pinned") else { throw E2EError("no pinned row in \(outline)") }
            try app.dragTab(a, onRow: pinned, childIndex: 0)
            let tiles = try await tiles(of: c) { $0.count == 1 }
            return (tiles: tiles, outline: try app.sidebarOutline(of: c))
        }
        let movedOutline = movedOut.outline.joined(separator: " | ")
        run.check(
            "favorites.move-out",
            passed: titles(movedOut.tiles) == "[B]"
                && movedOut.outline == ["favorites", "pinned", "A", "divider", "today", "C", "B"],
            "items=\(titles(movedOut.tiles)) outline=\(movedOutline)")

        let removed = try await run.step("remove B with its menu", timeout: E2ETimeouts.step) {
            let menu = try app.favoriteMenu(of: b)
            try app.chooseFavoriteMenuItem("Remove from Favorites", of: b)
            let tiles = try await tiles(of: c) { $0.isEmpty }
            return (
                menu: menu, tiles: tiles, outline: try app.sidebarOutline(of: c),
                height: try app.favoritesGridHeight(of: c).row
            )
        }
        run.check(
            "favorites.remove",
            passed: removed.menu == ["Remove from Favorites"] && removed.tiles.isEmpty && removed.height == empty
                && removed.outline == ["favorites", "pinned", "A", "divider", "today", "B", "C", "B"],
            "menu=\(removed.menu) items=\(titles(removed.tiles)) height=\(removed.height) "
                + "outline=\(removed.outline.joined(separator: " | "))")

        // Evidence only: the window ends showing C with A and B back in the grid, for the run's screenshot.
        try await run.step("leave Favorites for the screenshot", timeout: E2ETimeouts.step) {
            try app.dragToFavorites(a, at: 0)
            try app.dragToFavorites(b, at: 1)
            try app.clickSidebarRow(of: c)
            _ = try await tiles(of: c) { $0.count == 2 }
        }
    }
}
