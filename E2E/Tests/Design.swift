import Foundation

/// Tests of the window's look: the app icon in the bundle, one Frame colored surface under a transparent title bar,
/// the page as a White card with rounded corners and a soft shadow, and the active row lifted in Cocoa text. The
/// expected colors are the brand kit's hex values. `design.screens` also writes screenshots of the main states to
/// `<run>/design/` for the maintainer to look at. Fixtures in E2E/Fixtures/design/.
@MainActor
enum DesignTests {
    static let all: [any E2ETest] = [DesignLookTest(), DesignScreensTest()]

    /// The brand kit's colors (tokens/colors.css).
    static let cream = "#FFF3E6"
    static let white = "#FFFFFF"
    static let cocoa = "#3A1F14"
    static let night = "#2A1710"

    static func design(_ run: E2ERun) throws -> any E2EDesignApp {
        guard let app = run.app as? any E2EDesignApp else { throw E2EError("the app has no design hooks") }
        return app
    }

    static func url(_ title: String, dark: Bool = false) -> URL {
        E2EFixture.url("design/page.html?title=\(title)\(dark ? "&dark=1" : "")")
    }

    /// Opens `title` in a new tab of `page`'s window, selected or not, and waits for it to load.
    static func openTab(
        _ run: E2ERun, _ title: String, besides page: any E2EPage, select: Bool, dark: Bool = false
    ) async throws -> any E2EPage {
        try await run.step("open \(title)", timeout: E2ETimeouts.firstLoad) {
            let tab = try run.app.openTab(at: url(title, dark: dark), besides: page, select: select)
            if select { _ = try await tab.waitForLoad(after: 0) }
            return tab
        }
    }

    /// Waits until `condition` holds, or the step's wait budget runs out, and returns whether it held.
    static func until(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try condition()
    }
}

/// Reads the window's look with a page on screen, resizes the window, and switches to an empty Space.
struct DesignLookTest: E2ETest {
    let name = "design.look"
    let checks = [
        "design.app_icon", "design.title_bar", "design.page_card", "design.page_shadow",
        "design.shadow_follows_resize", "design.frame_color", "design.selected_row", "design.empty_mark",
    ]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no window edges") }
        let page = try await run.step("open a window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: DesignTests.url("Home"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let look = try await run.step("read the look", timeout: E2ETimeouts.step) {
            // The page card's top inset follows the title bar, which the window lays out once it is shown.
            _ = try await DesignTests.until { try design.look(of: page).pageInsets.first ?? 0 > 0 }
            return try design.look(of: page)
        }
        run.check(
            "design.app_icon", passed: look.iconName == "AppIcon" && look.iconFileExists,
            "icon=\(look.iconName ?? "none") file=\(look.iconFileExists)")
        run.check(
            "design.title_bar",
            passed: look.fullSizeContent && look.titlebarTransparent && look.windowButtonsOverSidebar
                && look.titleBarHeight > 0,
            "full_size=\(look.fullSizeContent) transparent=\(look.titlebarTransparent)"
                + " buttons_over_sidebar=\(look.windowButtonsOverSidebar) title_bar=\(look.titleBarHeight)")
        let insets = look.pageInsets
        run.check(
            "design.page_card",
            passed: insets == [look.titleBarHeight, 0, 8, 8] && look.pageCornerRadius == 14
                && look.pageCornerContinuous,
            "insets=\(insets) title_bar=\(look.titleBarHeight) radius=\(look.pageCornerRadius)"
                + " continuous=\(look.pageCornerContinuous)")
        run.check(
            "design.page_shadow",
            passed: look.pageShadowOpacity > 0 && look.pageShadowOpacity < 0.3 && look.pageShadowRadius >= 8
                && look.pageShadowHasPath && look.shadowFrame == look.pageFrame,
            "opacity=\(look.pageShadowOpacity) radius=\(look.pageShadowRadius) path=\(look.pageShadowHasPath)"
                + " page=\(look.pageFrame) shadow=\(look.shadowFrame)")
        run.check(
            "design.frame_color", passed: look.frameColor == DesignTests.cream, "frame=\(look.frameColor ?? "none")")
        run.check(
            "design.selected_row",
            passed: look.selectedRowBackground == DesignTests.white && look.selectedRowText == DesignTests.cocoa
                && look.selectedRowCornerRadius == 14,
            "background=\(look.selectedRowBackground ?? "none") text=\(look.selectedRowText ?? "none")"
                + " radius=\(look.selectedRowCornerRadius)")

        let resized = try await run.step("resize the window", timeout: E2ETimeouts.step) {
            try design.resizeWindow(of: page, width: 900, height: 600)
            _ = try await DesignTests.until {
                let now = try design.look(of: page)
                return now.pageFrame.width != look.pageFrame.width && now.shadowFrame == now.pageFrame
            }
            return try design.look(of: page)
        }
        run.check(
            "design.shadow_follows_resize",
            passed: resized.pageFrame.width != look.pageFrame.width && resized.shadowFrame == resized.pageFrame
                && resized.pageShadowHasPath,
            "before=\(look.pageFrame) page=\(resized.pageFrame) shadow=\(resized.shadowFrame)"
                + " path=\(resized.pageShadowHasPath)")

        let empty = try await run.step("switch to an empty Space", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            _ = try await DesignTests.until { try design.look(of: page).showsEmptyState }
            return try design.look(of: page)
        }
        run.check(
            "design.empty_mark", passed: empty.showsEmptyState && empty.emptyStateMarkSize >= 24,
            "empty=\(empty.showsEmptyState) mark=\(empty.emptyStateMarkSize)")
    }
}

/// Writes screenshots of the main states to `<run>/design/` (a window with a pinned tab, a Favorite and a selected
/// tab; the empty Space; dark appearance; the command bar open; a narrow window) and checks the dark colors.
struct DesignScreensTest: E2ETest {
    let name = "design.screens"
    let checks = ["design.screens", "design.dark_colors"]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp, let favorites = run.app as? any E2EFavoritesApp,
            let menus = run.app as? any E2EMenuApp, let bars = run.app as? any E2ECommandBarApp
        else { throw E2EError("the app lacks the window, Favorites, menu or command bar hooks") }
        let folder = run.dataDirectory.deletingLastPathComponent().appendingPathComponent("design", isDirectory: true)
        var written: [String] = []
        func shoot(_ page: any E2EPage, _ name: String) async throws {
            let url = folder.appendingPathComponent("\(name).png")
            try await design.writeScreenshot(of: page, to: url)
            written.append(url.lastPathComponent)
        }

        let docs = try await run.step("open a window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: DesignTests.url("Docs"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        try await run.step("pin a tab", timeout: E2ETimeouts.step) { try edges.pin(docs) }
        let mail = try await DesignTests.openTab(run, "Mail", besides: docs, select: true)
        try await run.step("make a Favorite", timeout: E2ETimeouts.step) { try favorites.dragToFavorites(mail, at: 0) }
        _ = try await DesignTests.openTab(run, "Reading", besides: docs, select: false)
        let notes = try await DesignTests.openTab(run, "Notes", besides: docs, select: true)
        try await run.step("1 window", timeout: E2ETimeouts.step) {
            _ = try await DesignTests.until { try design.look(of: notes).pageInsets.first ?? 0 > 0 }
            try await shoot(notes, "1-window")
        }

        let dark = try await run.step("3 dark", timeout: E2ETimeouts.step) {
            try design.setDarkAppearance(true, of: notes)
            _ = try await DesignTests.until { try design.look(of: notes).frameColor == DesignTests.night }
            try await shoot(notes, "3-dark")
            let look = try design.look(of: notes)
            try design.setDarkAppearance(false, of: notes)
            return look
        }
        run.check(
            "design.dark_colors",
            passed: dark.frameColor == DesignTests.night && dark.selectedRowBackground == DesignTests.cocoa
                && dark.selectedRowText == DesignTests.cream && dark.toolbarDark,
            "frame=\(dark.frameColor ?? "none") row=\(dark.selectedRowBackground ?? "none")"
                + " text=\(dark.selectedRowText ?? "none") toolbar_dark=\(dark.toolbarDark)")

        try await run.step("4 command bar", timeout: E2ETimeouts.step) {
            try menus.chooseMenuItem(key: "t", modifiers: [.command], in: notes)
            let bar = try bars.commandBar(of: notes)
            _ = try await DesignTests.until { bar.isShown }
            guard bar.isShown else { throw E2EError("the command bar did not open") }
            try await shoot(notes, "4-command-bar")
            try bar.press(.escape)
            _ = try await DesignTests.until { !bar.isShown }
        }

        try await run.step("5 narrow", timeout: E2ETimeouts.step) {
            try design.resizeWindow(of: notes, width: 640, height: 560)
            _ = try await DesignTests.until {
                let look = try design.look(of: notes)
                return look.pageFrame.width < 420 && look.shadowFrame == look.pageFrame
            }
            try await shoot(notes, "5-narrow")
            try design.resizeWindow(of: notes, width: 1200, height: 800)
        }

        try await run.step("2 empty Space", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: notes, profileID: edges.profileID(of: notes))
            _ = try await DesignTests.until { try design.look(of: notes).showsEmptyState }
            try await shoot(notes, "2-empty-space")
        }
        run.check(
            "design.screens", passed: written.count == 5,
            "wrote \(written.joined(separator: ", ")) in \(folder.path)")
    }
}
