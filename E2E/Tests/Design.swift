import Foundation

/// Tests of the window's look: the app icon in the bundle, one Frame colored surface under a transparent title bar
/// with no toolbar, the navigation buttons in the sidebar's top row beside the window buttons, the page as a card
/// with rounded corners and a soft shadow, and the active row lifted with a bold title. The expected colors are the
/// brand tokens' hex values. `design.screens` also writes screenshots of the main states to `<run>/design/` for the
/// maintainer to look at. Fixtures in E2E/Fixtures/design/.
@MainActor
enum DesignTests {
    static let all: [any E2ETest] = [DesignLookTest(), DesignScreensTest(), DesignFontsTest()]

    /// The brand tokens (light, then dark).
    static let frameLight = "#FFF3E6"
    static let frameDark = "#2A1710"
    static let textLight = "#3A1F14"
    static let textDark = "#FFF3E6"
    static let activeLight = "#FFFFFF"
    static let activeDark = "#3D2519"
    static let apricot = "#FFC08A"

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

    /// The state the checks and screenshots look at: a Space with a pinned tab, a pinned folder of two tabs and a
    /// today tab, one Favorite, and "Notes" open as the active tab. Returns the Notes page.
    static func openBrowsing(_ run: E2ERun) async throws -> any E2EPage {
        guard let favorites = run.app as? any E2EFavoritesApp, let seeds = run.app as? any E2EStoreSeedApp else {
            throw E2EError("the app lacks the Favorites or seed hooks")
        }
        let seed = E2ESeed(spaces: [
            E2ESeedSpace(
                "Home",
                pinned: [
                    .tab("Docs", url: url("Docs")),
                    .folder("Projects", [.tab("Plan", url: url("Plan")), .tab("Roadmap", url: url("Roadmap"))]),
                ],
                today: [.tab("Reading", url: url("Reading"))])
        ])
        let home = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await seeds.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let mail = try await openTab(run, "Mail", besides: home, select: true)
        try await run.step("make a Favorite", timeout: E2ETimeouts.step) { try favorites.dragToFavorites(mail, at: 0) }
        return try await openTab(run, "Notes", besides: home, select: true)
    }

    /// Opens the command bar over `page` with Command-T and waits until it shows.
    static func openCommandBar(_ run: E2ERun, over page: any E2EPage) async throws -> any E2ECommandBar {
        guard let menus = run.app as? any E2EMenuApp, let bars = run.app as? any E2ECommandBarApp else {
            throw E2EError("the app lacks the menu or command bar hooks")
        }
        try menus.chooseMenuItem(key: "t", modifiers: [.command], in: page)
        let bar = try bars.commandBar(of: page)
        _ = try await until { bar.isShown }
        guard bar.isShown else { throw E2EError("the command bar did not open") }
        return bar
    }
}

/// Reads the window's look with a Favorite, a pinned folder and the active tab on screen, then with the command bar
/// open, resizes the window, and switches to an empty Space.
struct DesignLookTest: E2ETest {
    let name = "design.look"
    let tags = ["smoke"]
    let checks = [
        "design.app_icon", "design.title_bar", "design.sidebar_top_row", "design.page_card", "design.page_shadow",
        "design.frame_color", "design.selected_row", "design.favorites", "design.folder_indent",
        "design.space_label", "design.space_dot", "design.command_bar", "design.shadow_follows_resize",
        "design.empty_mark",
    ]

    /// Where a tab directly in a section puts its icon, from the sidebar's leading edge: where it was before rows in
    /// folders stepped in 22 points, which must not move it.
    static let topIconX = 43.0

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no window edges") }
        let page = try await DesignTests.openBrowsing(run)
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
        // Four equal columns 8 apart fill the sidebar between its 14 point leading and 12 point trailing padding.
        let tile = look.favoriteTileFrame
        let columns = ((look.sidebarWidth - 12 - tile.minX + 8) / (tile.width + 8)).rounded()
        run.check(
            "design.favorites",
            passed: tile.minX == 14 && tile.width == (look.sidebarWidth - 14 - 12 - 3 * 8) / 4 && tile.height == 44
                && columns == 4,
            "tile=\(tile) columns=\(columns)")
        run.check(
            "design.folder_indent",
            passed: look.childIconX - look.topIconX == 22 && look.topIconX == Self.topIconX
                && look.childRowHeight == 32,
            "top_icon=\(look.topIconX) child_icon=\(look.childIconX) child_row=\(look.childRowHeight)")
        run.check(
            "design.space_label",
            passed: look.spaceNameFrame.height > 0 && look.spaceNameFrame.minY >= look.favoritesFrame.maxY
                && look.spaceNameFrame.maxY <= look.firstTabRowFrame.minY,
            "favorites=\(look.favoritesFrame) name=\(look.spaceNameFrame) first_row=\(look.firstTabRowFrame)")
        run.check(
            "design.space_dot",
            passed: look.spaceDotSize == 14 && look.spaceRingWidth == 2 && look.spaceRingGap == 2
                && look.spaceRingColor == DesignTests.apricot,
            "dot=\(look.spaceDotSize) ring=\(look.spaceRingWidth) gap=\(look.spaceRingGap)"
                + " ring_color=\(look.spaceRingColor ?? "none")")

        let bar = try await run.step("open the command bar", timeout: E2ETimeouts.step) {
            let bar = try await DesignTests.openCommandBar(run, over: page)
            let look = try design.look(of: page)
            try bar.press(.escape)
            _ = try await DesignTests.until { !bar.isShown }
            return look
        }
        run.check(
            "design.command_bar",
            passed: bar.commandBarRadius == 14 && bar.commandBarClips && bar.commandBarShadowHasPath,
            "radius=\(bar.commandBarRadius) clips=\(bar.commandBarClips) shadow_path=\(bar.commandBarShadowHasPath)")

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
        guard let edges = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no window edges") }
        let folder = run.dataDirectory.deletingLastPathComponent().appendingPathComponent("design", isDirectory: true)
        var written: [String] = []
        func shoot(_ page: any E2EPage, _ name: String) async throws {
            let url = folder.appendingPathComponent("\(name).png")
            try await design.writeScreenshot(of: page, to: url)
            written.append(url.lastPathComponent)
        }

        let notes = try await DesignTests.openBrowsing(run)
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
            let bar = try await DesignTests.openCommandBar(run, over: notes)
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

/// The brand fonts: the app registered the bundled Nunito Sans and Fredoka (and carries no JetBrains Mono), their
/// licenses are in Resources, and the sidebar, command bar and empty state draw with Nunito Sans at the sizes the
/// styling guide gives, the active row bold.
struct DesignFontsTest: E2ETest {
    let name = "design.fonts"
    let checks = ["design.fonts_registered", "design.fonts_sidebar", "design.fonts_command_bar", "design.fonts_empty"]

    func run(_ run: E2ERun) async throws {
        guard let fonts = run.app as? any E2EFontsApp else { throw E2EError("the app has no font hooks") }
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no window edges") }
        let page = try await DesignTests.openBrowsing(run)
        let nunito = "Nunito Sans"
        let browsing = try await run.step("read the sidebar fonts", timeout: E2ETimeouts.step) {
            try fonts.fonts(of: page)
        }
        run.check(
            "design.fonts_registered",
            passed: browsing.nunitoRegistered && browsing.nunitoFromApp && browsing.fredokaRegistered
                && !browsing.jetBrainsPresent
                && browsing.fontFilesBundled && browsing.licenseFilesBundled
                && browsing.uiToken == E2EFontInfo(family: nunito, name: browsing.uiToken.name, size: 13.5)
                && browsing.displayToken.family == "Fredoka" && browsing.displayToken.name.contains("SemiBold")
                && browsing.displayToken.size == 40,
            "nunito=\(browsing.nunitoRegistered) from_app=\(browsing.nunitoFromApp) fredoka=\(browsing.fredokaRegistered)"
                + " jetbrains=\(browsing.jetBrainsPresent) files=\(browsing.fontFilesBundled)"
                + " licenses=\(browsing.licenseFilesBundled) ui=\(browsing.uiToken) display=\(browsing.displayToken)")
        run.check(
            "design.fonts_sidebar",
            passed: browsing.activeRow?.family == nunito && browsing.activeRow?.size == 13.5
                && browsing.activeRow?.name.contains("Bold") == true && browsing.spaceName?.family == nunito
                && browsing.spaceName?.size == 11 && browsing.spaceName?.name.contains("Bold") == true,
            "active_row=\(String(describing: browsing.activeRow)) space_name=\(String(describing: browsing.spaceName))")

        let bar = try await run.step("read the command bar font", timeout: E2ETimeouts.step) {
            let bar = try await DesignTests.openCommandBar(run, over: page)
            let look = try fonts.fonts(of: page)
            try bar.press(.escape)
            _ = try await DesignTests.until { !bar.isShown }
            return look
        }
        run.check(
            "design.fonts_command_bar",
            passed: bar.commandBarField?.family == nunito && bar.commandBarField?.size == 20,
            "field=\(String(describing: bar.commandBarField))")

        let empty = try await run.step("read the empty state font", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            _ = try await DesignTests.until { try design.look(of: page).showsEmptyState }
            return try fonts.fonts(of: page)
        }
        run.check(
            "design.fonts_empty", passed: empty.emptyStateLine?.family == nunito && empty.emptyStateLine?.size == 15,
            "line=\(String(describing: empty.emptyStateLine))")
    }
}
