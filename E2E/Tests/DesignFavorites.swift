import Foundation

/// The Favorites grid: tiles 44 points tall in four equal columns 8 points apart, filling the sidebar between its
/// padding.
@MainActor
enum DesignFavoritesTests {
    static let all: [any E2ETest] = [DesignFavoritesTest()]
}

struct DesignFavoritesTest: E2ETest {
    let name = "design.favorites"
    let checks = ["design.favorites"]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        let page = try await DesignTests.openBrowsing(run)
        let look = try await run.step("read the Favorites", timeout: E2ETimeouts.step) {
            try design.look(of: page)
        }
        // Four equal columns 8 apart fill the sidebar between its 14 point leading and 12 point trailing padding.
        let width = look.frame.sidebarWidth
        let tile = look.favorites.tileFrame
        let columns = ((width - 12 - tile.minX + 8) / (tile.width + 8)).rounded()
        run.check(
            "design.favorites",
            passed: tile.minX == 14 && tile.width == (width - 14 - 12 - 3 * 8) / 4 && tile.height == 44
                && columns == 4 && look.favorites.tileCount == E2EDesignFixture.favorites.count,
            "tile=\(tile) columns=\(columns) tiles=\(look.favorites.tileCount)")
    }
}
