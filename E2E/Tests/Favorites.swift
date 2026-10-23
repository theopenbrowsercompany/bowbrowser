import Foundation

/// Tests of the Favorites grid at the top of the sidebar. Uses the sidebar fixtures in E2E/Fixtures/sidebar/.
@MainActor
enum FavoritesGridTests {
    static let all: [any E2ETest] = [FavoritesGridTest(), FavoritesActiveTabTest(), FavoritesEmptySpaceTest()]

    /// What `read` gives once `condition` holds for it, or what it gave last when the wait's budget (at most 3 seconds
    /// of the step's time) runs out, so the check that follows says what it saw.
    static func settle<T>(_ read: () throws -> T, until condition: (T) -> Bool) async throws -> T {
        let deadline = Date().addingTimeInterval(E2EWaits.budget(limit: 3))
        var value = try read()
        while !condition(value), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            value = try read()
        }
        return value
    }

    static func titles(_ tiles: [E2EFavoriteTile]) -> String { "[\(tiles.map(\.title).joined(separator: ","))]" }
}

/// Opens tabs A, B and C, and drags A then B onto the grid: both leave today and show as tiles with their site icons,
/// in a grid sized to its one row. Drags B before A, clicks B (B itself shows in place, its tile lit, with no copy in
/// today, also on a second click), drags A out to pinned, and removes B with its menu (its own page goes back to the
/// top of today).
struct FavoritesGridTest: E2ETest {
    let name = "favorites"
    let tags = ["smoke"]
    let checks = ["favorites", "favorites.reorder", "favorites.open", "favorites.move-out", "favorites.remove"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EFavoritesApp else { throw E2EError("the app has no Favorites grid") }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
        func settle<T>(_ read: () throws -> T, until condition: (T) -> Bool) async throws -> T {
            try await FavoritesGridTests.settle(read, until: condition)
        }
        /// The grid's tiles in `page`'s window once `condition` holds for them, or as they are when the wait gives up.
        func tiles(of page: any E2EPage, until condition: ([E2EFavoriteTile]) -> Bool) async throws
            -> [E2EFavoriteTile]
        {
            try await settle({ try app.favoriteTiles(of: page) }, until: condition)
        }
        let titles = FavoritesGridTests.titles

        let a = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: url("A"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let (b, c) = try await run.step("new tabs B and C", timeout: E2ETimeouts.firstLoad) {
            let b = try await app.clickNewTab(besides: a, opening: url("B"))
            _ = try await b.waitForLoad(after: 0)
            let c = try await app.clickNewTab(besides: a, opening: url("C"))
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

        let loadedBefore = try app.activeTab(of: c).loadedCount
        /// What the window shows: the today rows, the grid's tiles and the active tab.
        func shown() throws -> (rows: [E2ESidebarRow], tiles: [E2EFavoriteTile], active: E2EActiveTab) {
            (try app.sidebarRows(of: c), try app.favoriteTiles(of: c), try app.activeTab(of: c))
        }
        /// B itself shown in place: its tile lit, its own page shown, no today row for it, nothing new loaded.
        func showsB(_ seen: (rows: [E2ESidebarRow], tiles: [E2EFavoriteTile], active: E2EActiveTab)) -> Bool {
            SidebarWaits.summary(seen.rows) == "tabs=[C] active=none" && seen.tiles.first?.isActive == true
                && b.isShown && seen.active.title == "B" && seen.active.loadedCount == loadedBefore
        }
        func describe(_ seen: (rows: [E2ESidebarRow], tiles: [E2EFavoriteTile], active: E2EActiveTab)) -> String {
            "\(SidebarWaits.summary(seen.rows)) tiles=\(seen.tiles) active=\(seen.active)"
        }
        let opened = try await run.step("click B twice", timeout: E2ETimeouts.firstLoad) {
            try app.clickFavorite(b)
            let first = try await settle(shown, until: showsB)
            let firstShown = b.isShown
            try app.clickSidebarRow(of: c)
            let away = try await settle(shown) {
                SidebarWaits.summary($0.rows) == "tabs=[C] active=C" && $0.tiles.first?.isActive == false
            }
            try app.clickFavorite(b)
            let second = try await settle(shown, until: showsB)
            return (first: first, firstShown: firstShown, away: away, second: second, secondShown: b.isShown)
        }
        run.check(
            "favorites.open",
            passed: showsB(opened.first) && opened.firstShown
                && SidebarWaits.summary(opened.away.rows) == "tabs=[C] active=C"
                && opened.away.tiles.first?.isActive == false && showsB(opened.second) && opened.secondShown,
            "first=\(describe(opened.first)) b_shown=\(opened.firstShown) away=\(describe(opened.away)) "
                + "second=\(describe(opened.second)) b_shown=\(opened.secondShown) loaded_before=\(loadedBefore)")

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
                && movedOut.outline == ["favorites", "pinned", "A", "divider", "today", "C"],
            "items=\(titles(movedOut.tiles)) outline=\(movedOutline)")

        let removed = try await run.step("remove B with its menu", timeout: E2ETimeouts.step) {
            let menu = try app.favoriteMenu(of: b)
            try app.chooseFavoriteMenuItem("Remove from Favorites", of: b)
            let tiles = try await tiles(of: c) { $0.isEmpty }
            return (
                menu: menu, tiles: tiles, outline: try app.sidebarOutline(of: c),
                height: try app.favoritesGridHeight(of: c).row, zone: try app.sidebarZone(of: b)
            )
        }
        // B keeps its own page as it goes back to today, so there is one B and nothing closed or duplicated.
        run.check(
            "favorites.remove",
            passed: removed.menu == ["Remove from Favorites"] && removed.tiles.isEmpty && removed.height == empty
                && removed.outline == ["favorites", "pinned", "A", "divider", "today", "B", "C"]
                && !b.isClosed && removed.zone == "today",
            "menu=\(removed.menu) items=\(titles(removed.tiles)) height=\(removed.height) "
                + "outline=\(removed.outline.joined(separator: " | ")) b_closed=\(b.isClosed) "
                + "b_zone=\(removed.zone ?? "none")")

        // Evidence only: the window ends showing C with A and B back in the grid, for the run's screenshot.
        try await run.step("leave Favorites for the screenshot", timeout: E2ETimeouts.step) {
            try app.dragToFavorites(a, at: 0)
            try app.dragToFavorites(b, at: 1)
            try app.clickSidebarRow(of: c)
            _ = try await tiles(of: c) { $0.count == 2 }
        }
    }
}

/// Opens tabs A and D, and drags D, the active tab, onto the grid: D stays the active tab, shown in place with its tile
/// lit, and the address bar and Back act on it. Close Tab (Cmd+W) then unloads D, which stays a Favorite while A
/// shows, and a click on its tile loads D in place on its saved address, not the page it navigated to.
struct FavoritesActiveTabTest: E2ETest {
    let name = "favorites.active-tab"
    let checks = ["favorites.active-tab", "favorites.close"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EFavoritesApp else { throw E2EError("the app has no Favorites grid") }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
        func settle<T>(_ read: () throws -> T, until condition: (T) -> Bool) async throws -> T {
            try await FavoritesGridTests.settle(read, until: condition)
        }
        let titles = FavoritesGridTests.titles

        let (a, d) = try await run.step("open A and D", timeout: E2ETimeouts.firstLoad) {
            let a = try await run.app.openWindow(at: url("A"))
            _ = try await a.waitForLoad(after: 0)
            let d = try await app.clickNewTab(besides: a, opening: url("D"))
            _ = try await d.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { SidebarWaits.summary($0) == "tabs=[A,D] active=D" }
            return (a, d)
        }

        let dragged = try await run.step("drag active D onto the grid", timeout: E2ETimeouts.step) {
            try app.dragToFavorites(d, at: 0)
            let tiles = try await settle({ try app.favoriteTiles(of: a) }) { $0.first?.isActive == true }
            let active = try app.activeTab(of: a)
            let rows = try app.sidebarRows(of: a)
            // The address bar loads into the active tab, and Back then goes back in it.
            let loads = d.finishedLoads
            try d.load(url("D2"))
            _ = try await d.waitForLoad(after: loads)
            let back = try await settle({ try app.toolbarButton(.back, in: a) }) { $0.isEnabled }
            let navigated = try await settle({ try app.activeTab(of: a) }) { $0.url == url("D2").absoluteString }
            return (tiles: tiles, active: active, rows: rows, back: back, navigated: navigated, shown: d.isShown)
        }
        run.check(
            "favorites.active-tab",
            passed: titles(dragged.tiles) == "[D]" && dragged.tiles.first?.isActive == true
                && dragged.active.title == "D" && dragged.active.isShown
                && SidebarWaits.summary(dragged.rows) == "tabs=[A] active=none" && dragged.back.isEnabled
                && dragged.navigated.url == url("D2").absoluteString && dragged.shown,
            "tiles=\(dragged.tiles) active=\(dragged.active) rows=\(SidebarWaits.summary(dragged.rows)) "
                + "back=\(dragged.back) after_load=\(dragged.navigated) d_shown=\(dragged.shown)")

        let closed = try await run.step("Cmd+W, then click D", timeout: E2ETimeouts.firstLoad) {
            try app.chooseMenuItem(commandKey: "w", in: a)
            let closedD = try await settle({ d.isClosed }) { $0 }
            let after = try await settle({ (rows: try app.sidebarRows(of: a), tiles: try app.favoriteTiles(of: a)) }) {
                SidebarWaits.summary($0.rows) == "tabs=[A] active=A"
            }
            let afterClose = try app.activeTab(of: a)
            try app.clickFavorite(titled: "D", in: a)
            let reopened = try await settle({ try app.activeTab(of: a) }) {
                $0.isShown && $0.url == url("D").absoluteString && $0.title == "D"
            }
            let tiles = try await settle({ try app.favoriteTiles(of: a) }) { $0.first?.isActive == true }
            let rows = try app.sidebarRows(of: a)
            return (
                closedD: closedD, after: after, afterClose: afterClose, reopened: reopened, tiles: tiles, rows: rows
            )
        }
        run.check(
            "favorites.close",
            passed: closed.closedD && titles(closed.after.tiles) == "[D]"
                && closed.after.tiles.first?.isActive == false
                && SidebarWaits.summary(closed.after.rows) == "tabs=[A] active=A" && closed.afterClose.title == "A"
                && closed.reopened.title == "D" && closed.reopened.isShown
                && closed.reopened.url == url("D").absoluteString && closed.reopened.loadedCount == 2
                && closed.tiles.first?.isActive == true && SidebarWaits.summary(closed.rows) == "tabs=[A] active=none",
            "d_closed=\(closed.closedD) tiles_after_close=\(closed.after.tiles) "
                + "rows_after_close=\(SidebarWaits.summary(closed.after.rows)) active_after_close=\(closed.afterClose) "
                + "reopened=\(closed.reopened) tiles=\(closed.tiles) rows=\(SidebarWaits.summary(closed.rows))")
    }
}

/// Opens A and B and drags A, with its site icon, onto the grid, then switches to a new empty Space of the same profile
/// and adds Favorite S, saved and never loaded. The empty Space lists both Favorites: the start screen's quick links
/// show A's icon and S's letter, and clicking S's tile in the sidebar loads S in place, the start screen giving way.
/// After a switch to the first Space and back, clicking A's tile shows A's own page.
struct FavoritesEmptySpaceTest: E2ETest {
    let name = "favorites.empty-space"
    let checks = ["favorites.empty-space", "favorites.empty-space-icons"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EFavoritesApp, let edges = run.app as? any E2EWindowEdgesApp,
            let start = run.app as? any E2EStartScreenApp
        else { throw E2EError("the app lacks the Favorites, window edges or start screen hooks") }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
        func settle<T>(_ read: () throws -> T, until condition: (T) -> Bool) async throws -> T {
            try await FavoritesGridTests.settle(read, until: condition)
        }
        let titles = FavoritesGridTests.titles

        let (a, home) = try await run.step("open A and B, drag A onto the grid", timeout: E2ETimeouts.firstLoad) {
            let a = try await run.app.openWindow(at: url("A"))
            _ = try await a.waitForLoad(after: 0)
            let b = try await app.clickNewTab(besides: a, opening: url("B"))
            _ = try await b.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B"] && $0.allSatisfy(\.hasFavicon) }
            try app.dragToFavorites(a, at: 0)
            let tiles = try await settle({ try app.favoriteTiles(of: a) }) { titles($0) == "[A]" && $0[0].hasIcon }
            guard titles(tiles) == "[A]" else { throw E2EError("the grid shows \(titles(tiles)), not [A]") }
            return (a, try edges.activeSpace(besides: a))
        }

        let empty = try await run.step("switch to an empty Space and add Favorite S", timeout: E2ETimeouts.step) {
            let space = try edges.createSpace(besides: a, profileID: edges.profileID(of: a))
            _ = try start.addFavorite(title: "S", url: url("S"), in: a)
            let look = try await settle({ try start.startScreen(of: a) }) {
                $0.isShown && $0.linkTitles == ["A", "S"] && $0.linkIcons == [true, false]
            }
            let tiles = try app.favoriteTiles(of: a)
            return (space: space, look: look, tiles: tiles)
        }
        run.check(
            "favorites.empty-space-icons",
            passed: empty.look.isShown && empty.look.linkTitles == ["A", "S"] && empty.look.linkIcons == [true, false]
                && titles(empty.tiles) == "[A,S]" && empty.tiles.map(\.hasIcon) == [true, false],
            "start_shown=\(empty.look.isShown) links=\(empty.look.linkTitles) link_icons=\(empty.look.linkIcons) "
                + "tiles=\(empty.tiles)")

        /// What the window shows: the active tab, whether the start screen shows, and the grid's tiles.
        func shown() throws -> (active: E2EActiveTab, start: Bool, tiles: [E2EFavoriteTile]) {
            (try app.activeTab(of: a), try start.startScreen(of: a).isShown, try app.favoriteTiles(of: a))
        }
        func describe(_ seen: (active: E2EActiveTab, start: Bool, tiles: [E2EFavoriteTile])) -> String {
            "active=\(seen.active) start=\(seen.start) tiles=\(seen.tiles)"
        }
        func shows(_ title: String) -> ((active: E2EActiveTab, start: Bool, tiles: [E2EFavoriteTile])) -> Bool {
            { seen in
                seen.active.title == title && seen.active.isShown && seen.active.url == url(title).absoluteString
                    && !seen.start && seen.tiles.first { $0.title == title }?.isActive == true
            }
        }
        let opened = try await run.step("click S, switch away and back, click A", timeout: E2ETimeouts.firstLoad) {
            try app.clickFavorite(titled: "S", in: a)
            let s = try await settle(shown, until: shows("S"))
            try edges.switchToSpace(home, besides: a)
            _ = try await settle({ try edges.activeSpace(besides: a) }) { $0 == home }
            try edges.switchToSpace(empty.space, besides: a)
            _ = try await settle({ try edges.activeSpace(besides: a) }) { $0 == empty.space }
            try app.clickFavorite(titled: "A", in: a)
            let shownA = try await settle(shown, until: shows("A"))
            return (s: s, a: shownA, aShown: a.isShown)
        }
        run.check(
            "favorites.empty-space",
            passed: shows("S")(opened.s) && shows("A")(opened.a) && opened.aShown,
            "after_s=\(describe(opened.s)) after_a=\(describe(opened.a)) a_page_shown=\(opened.aShown)")
    }
}
