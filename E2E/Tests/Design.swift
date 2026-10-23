import Foundation

/// Tests of the window's look: the app icon in the bundle, one Frame colored surface under a transparent title bar
/// with no toolbar, the navigation buttons in the sidebar's top row beside the window buttons, the page as a card
/// with rounded corners and a soft shadow, and the active row lifted with a bold title. The expected colors are the
/// brand tokens' hex values. `design.screens` also writes screenshots of the main states to `<run>/design/` for the
/// maintainer to look at. Fixtures in E2E/Fixtures/design/.
@MainActor
enum DesignTests {
    static let all: [any E2ETest] = [DesignLookTest(), DesignScreensTest()]

    /// The brand tokens (light, then dark).
    static let frameLight = "#FFF3E6"
    static let frameDark = "#2A1710"
    static let textLight = "#3A1F14"
    static let textDark = "#FFF3E6"
    static let activeLight = "#FFFFFF"
    static let activeDark = "#3D2519"

    static func design(_ run: E2ERun) throws -> any E2EDesignApp {
        guard let app = run.app as? any E2EDesignApp else { throw E2EError("the app has no design hooks") }
        return app
    }

    static func url(_ title: String) -> URL {
        E2EFixture.url("design/page.html?title=\(title)")
    }

    /// Opens `title` in a new tab of `page`'s window, selected or not, and waits for it to load when selected.
    static func openTab(_ run: E2ERun, _ title: String, besides page: any E2EPage, select: Bool) async throws
        -> any E2EPage
    {
        try await run.step("open \(title)", timeout: E2ETimeouts.firstLoad) {
            let tab = try run.app.openTab(at: url(title), besides: page, select: select)
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
        "design.app_icon", "design.title_bar", "design.sidebar_top_row", "design.page_card", "design.page_shadow",
        "design.frame_color", "design.selected_row", "design.shadow_follows_resize", "design.empty_mark",
    ]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no window edges") }
        let page = try await run.step("open a window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: DesignTests.url("Home"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let look = try await run.step("read the look", timeout: E2ETimeouts.step) { try design.look(of: page) }
        run.check(
            "design.app_icon", passed: look.iconName == "AppIcon" && look.iconFileExists,
            "icon=\(look.iconName ?? "none") file=\(look.iconFileExists)")
        run.check(
            "design.title_bar",
            passed: look.fullSizeContent && look.titlebarTransparent && !look.hasToolbar
                && look.windowButtonsOverSidebar,
            "full_size=\(look.fullSizeContent) transparent=\(look.titlebarTransparent) toolbar=\(look.hasToolbar)"
                + " buttons_over_sidebar=\(look.windowButtonsOverSidebar)")
        run.check(
            "design.sidebar_top_row", passed: look.sidebarWidth == 264 && look.navigationInSidebarRow,
            "sidebar_width=\(look.sidebarWidth) navigation_in_row=\(look.navigationInSidebarRow)")
        run.check(
            "design.page_card",
            passed: look.pageInsets == [8, 0, 8, 8] && look.pageCornerRadius == 10 && look.pageCornerContinuous
                && look.pageTopClickable,
            "insets=\(look.pageInsets) radius=\(look.pageCornerRadius) continuous=\(look.pageCornerContinuous)"
                + " top_clickable=\(look.pageTopClickable)")
        run.check(
            "design.page_shadow",
            passed: look.pageShadowOpacity > 0 && look.pageShadowOpacity < 0.3 && look.pageShadowRadius > 0
                && look.pageShadowHasPath && look.shadowFrame == look.pageFrame,
            "opacity=\(look.pageShadowOpacity) radius=\(look.pageShadowRadius) path=\(look.pageShadowHasPath)"
                + " page=\(look.pageFrame) shadow=\(look.shadowFrame)")
        run.check(
            "design.frame_color", passed: look.frameColor == DesignTests.frameLight,
            "frame=\(look.frameColor ?? "none")")
        run.check(
            "design.selected_row",
            passed: look.selectedRowBackground == DesignTests.activeLight
                && look.selectedRowText == DesignTests.textLight && look.selectedRowBold
                && look.selectedRowHeight == 34 && look.selectedRowCornerRadius == 9
                && look.selectedRowShadowOpacity > 0,
            "background=\(look.selectedRowBackground ?? "none") text=\(look.selectedRowText ?? "none")"
                + " bold=\(look.selectedRowBold) height=\(look.selectedRowHeight)"
                + " radius=\(look.selectedRowCornerRadius) shadow=\(look.selectedRowShadowOpacity)")

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

/// Writes screenshots of the main states to `<run>/design/`: browsing with a Favorite, a pinned folder and the active
/// tab; the same in dark; the command bar open; a narrow window; the empty Space. Checks the dark colors.
struct DesignScreensTest: E2ETest {
    let name = "design.screens"
    let checks = ["design.screens", "design.dark_colors"]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp, let favorites = run.app as? any E2EFavoritesApp,
            let menus = run.app as? any E2EMenuApp, let bars = run.app as? any E2ECommandBarApp,
            let seeds = run.app as? any E2EStoreSeedApp
        else { throw E2EError("the app lacks the window, Favorites, menu, command bar or seed hooks") }
        let folder = run.dataDirectory.deletingLastPathComponent().appendingPathComponent("design", isDirectory: true)
        var written: [String] = []
        func shoot(_ page: any E2EPage, _ name: String) async throws {
            let url = folder.appendingPathComponent("\(name).png")
            try await design.writeScreenshot(of: page, to: url)
            written.append(url.lastPathComponent)
        }

        let seed = E2ESeed(spaces: [
            E2ESeedSpace(
                "Home",
                pinned: [
                    .tab("Docs", url: DesignTests.url("Docs")),
                    .folder(
                        "Projects",
                        [
                            .tab("Plan", url: DesignTests.url("Plan")),
                            .tab("Roadmap", url: DesignTests.url("Roadmap")),
                        ]),
                ],
                today: [.tab("Reading", url: DesignTests.url("Reading"))])
        ])
        let home = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await seeds.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let mail = try await DesignTests.openTab(run, "Mail", besides: home, select: true)
        try await run.step("make a Favorite", timeout: E2ETimeouts.step) { try favorites.dragToFavorites(mail, at: 0) }
        let notes = try await DesignTests.openTab(run, "Notes", besides: home, select: true)
        try await run.step("browsing", timeout: E2ETimeouts.step) { try await shoot(notes, "1-browsing") }

        let dark = try await run.step("dark", timeout: E2ETimeouts.step) {
            try design.setDarkAppearance(true, of: notes)
            _ = try await DesignTests.until { try design.look(of: notes).frameColor == DesignTests.frameDark }
            try await shoot(notes, "2-dark")
            let look = try design.look(of: notes)
            try design.setDarkAppearance(false, of: notes)
            return look
        }
        run.check(
            "design.dark_colors",
            passed: dark.frameColor == DesignTests.frameDark && dark.selectedRowBackground == DesignTests.activeDark
                && dark.selectedRowText == DesignTests.textDark && dark.navigationDark,
            "frame=\(dark.frameColor ?? "none") row=\(dark.selectedRowBackground ?? "none")"
                + " text=\(dark.selectedRowText ?? "none") navigation_dark=\(dark.navigationDark)")

        try await run.step("command bar", timeout: E2ETimeouts.step) {
            try menus.chooseMenuItem(key: "t", modifiers: [.command], in: notes)
            let bar = try bars.commandBar(of: notes)
            _ = try await DesignTests.until { bar.isShown }
            guard bar.isShown else { throw E2EError("the command bar did not open") }
            try await shoot(notes, "3-command-bar")
            try bar.press(.escape)
            _ = try await DesignTests.until { !bar.isShown }
        }

        try await run.step("narrow", timeout: E2ETimeouts.step) {
            try design.resizeWindow(of: notes, width: 640, height: 560)
            _ = try await DesignTests.until {
                let look = try design.look(of: notes)
                return look.pageFrame.width < 400 && look.shadowFrame == look.pageFrame
            }
            try await shoot(notes, "4-narrow")
            try design.resizeWindow(of: notes, width: 1200, height: 800)
        }

        try await run.step("empty Space", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: notes, profileID: edges.profileID(of: notes))
            _ = try await DesignTests.until { try design.look(of: notes).showsEmptyState }
            try await shoot(notes, "5-empty-space")
        }
        run.check(
            "design.screens", passed: written.count == 5,
            "wrote \(written.joined(separator: ", ")) in \(folder.path)")
    }
}
