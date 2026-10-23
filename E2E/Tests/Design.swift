import Foundation

/// Tests of the window's look: the app icon in the bundle, one Frame colored surface under a transparent title bar
/// with no toolbar, the navigation buttons in the sidebar's top row beside the window buttons, the page as a card
/// with rounded corners and a soft shadow, and the active row lifted with a bold title. The expected colors are the
/// brand tokens' hex values. `design.screens` also writes screenshots of the main states to `<run>/design/` for the
/// maintainer to look at. Fixtures in E2E/Fixtures/design/.
@MainActor
enum DesignTests {
    static let all: [any E2ETest] = [
        DesignLookTest(), DesignScreensTest(), DesignFontsTest(), DesignStartScreenTest(),
    ]

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
        // An empty Space shows the start screen, whose hint is 13 point Nunito Sans.
        run.check(
            "design.fonts_empty", passed: empty.emptyStateLine?.family == nunito && empty.emptyStateLine?.size == 13,
            "line=\(String(describing: empty.emptyStateLine))")
    }
}

/// The start screen of an empty Space (the styling guide's first mockup): the Bow mark at 64, the greeting for the
/// hour the app read (Fredoka 600 at 40), the 560 by 52 search pill that opens the command bar as Cmd+T does, the
/// profile's first six Favorites as quick links and the hint naming the Space, 26 points apart. Also: no Favorites
/// hides the row, a Favorite deleted while the screen shows leaves it, a quick link opens its Favorite, switching
/// between empty Spaces renames the hint, a long name is cut, a narrow window keeps everything inside the card, and
/// in the dark appearance the screen still draws light on the White card.
struct DesignStartScreenTest: E2ETest {
    let name = "design.start_screen"
    let checks = [
        "design.start_greeting", "design.start_hint", "design.start_search", "design.start_links",
        "design.start_layout", "design.start_narrow", "design.start_dark",
    ]

    /// The greeting the styling guide gives for a local hour: morning 5 to 12, afternoon 12 to 18, else evening.
    static func greeting(for hour: Int) -> String {
        switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    static func hint(_ space: String, tabs: Int) -> String {
        "\(space) \u{00B7} \(tabs) \(tabs == 1 ? "tab" : "tabs") \u{00B7} press \u{2318}T to search"
    }

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp, let start = run.app as? any E2EStartScreenApp,
            let seeds = run.app as? any E2EStoreSeedApp, let bars = run.app as? any E2ECommandBarApp
        else { throw E2EError("the app lacks the window edges, start screen, seed or command bar hooks") }
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let seed = E2ESeed(spaces: [E2ESeedSpace("Home", today: [.tab("Reading", url: DesignTests.url("Reading"))])])
            let window = try await seeds.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let folder = run.dataDirectory.deletingLastPathComponent().appendingPathComponent("design", isDirectory: true)
        func shown() async throws -> E2EStartScreenLook {
            _ = try await DesignTests.until { try start.startScreen(of: page).isShown }
            let look = try start.startScreen(of: page)
            guard look.isShown else { throw E2EError("the start screen is not shown") }
            return look
        }

        // An empty Space of the same profile, which has no Favorites yet.
        let first = try await run.step("switch to an empty Space", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            try start.renameActiveSpace("Work Space", in: page)
            _ = try await DesignTests.until { try start.startScreen(of: page).hint.hasPrefix("Work Space") }
            return try await shown()
        }
        let expectedGreeting = Self.greeting(for: first.greetingHour)
        run.check(
            "design.start_greeting",
            passed: first.greeting == expectedGreeting && (0...23).contains(first.greetingHour)
                && first.greetingFont?.family == "Fredoka" && first.greetingFont?.name.contains("SemiBold") == true
                && first.greetingFont?.size == 40 && first.greetingColor == DesignTests.textLight
                && first.markSize == CGSize(width: 64, height: 64),
            "greeting=\"\(first.greeting)\" hour=\(first.greetingHour) expected=\"\(expectedGreeting)\""
                + " font=\(String(describing: first.greetingFont)) color=\(first.greetingColor ?? "none")"
                + " mark=\(first.markSize)")

        // Another empty Space while the screen shows, then a name too long to show whole.
        let second = try await run.step("switch to a second empty Space with a long name", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            try start.renameActiveSpace("Side", in: page)
            _ = try await DesignTests.until { try start.startScreen(of: page).hint == Self.hint("Side", tabs: 0) }
            let side = try start.startScreen(of: page)
            try start.renameActiveSpace(String(repeating: "Long ", count: 20), in: page)
            _ = try await DesignTests.until { try start.startScreen(of: page).hint.contains("\u{2026}") }
            return (side, try start.startScreen(of: page))
        }
        let long = second.1
        run.check(
            "design.start_hint",
            passed: first.hint == Self.hint("Work Space", tabs: 0) && second.0.hint == Self.hint("Side", tabs: 0)
                && long.hint.hasSuffix("\u{2026} \u{00B7} 0 tabs \u{00B7} press \u{2318}T to search")
                && long.contentFrame.minX >= long.bounds.minX && long.contentFrame.maxX <= long.bounds.maxX
                && first.hintFont?.family == "Nunito Sans" && first.hintFont?.size == 13
                && first.hintColor == "#7A5A48",
            "first=\"\(first.hint)\" second=\"\(second.0.hint)\" long=\"\(long.hint)\""
                + " font=\(String(describing: first.hintFont)) color=\(first.hintColor ?? "none")")

        let opened = try await run.step("click the search pill", timeout: E2ETimeouts.step) {
            let bar = try bars.commandBar(of: page)
            try start.clickStartSearch(in: page)
            _ = try await DesignTests.until { bar.isShown }
            let result = (bar.isShown, bar.text)
            if bar.isShown {
                try bar.press(.escape)
                _ = try await DesignTests.until { !bar.isShown }
            }
            return result
        }
        run.check(
            "design.start_search",
            passed: opened.0 && opened.1.isEmpty && first.pillFrame.size == CGSize(width: 560, height: 52)
                && first.pillRadius == 26 && first.pillFill == "#FFFFFF" && first.pillBorder == "#F0DCC8"
                && first.pillBorderWidth == 1 && first.placeholder == "Search or type a URL"
                && first.placeholderFont?.family == "Nunito Sans" && first.placeholderFont?.size == 16,
            "bar_shown=\(opened.0) text=\"\(opened.1)\" pill=\(first.pillFrame.size) radius=\(first.pillRadius)"
                + " fill=\(first.pillFill ?? "none") border=\(first.pillBorder ?? "none")/\(first.pillBorderWidth)"
                + " placeholder=\"\(first.placeholder)\" font=\(String(describing: first.placeholderFont))")

        // Seven Favorites show as six links in sidebar order; deleting the first while the screen shows moves the
        // seventh in; clicking a link shows that Favorite.
        let names = (1...7).map { "Site \($0)" }
        let added = try await run.step("add seven Favorites", timeout: E2ETimeouts.step) {
            try design.resizeWindow(of: page, width: 1200, height: 800)
            try start.renameActiveSpace("Work Space", in: page)
            let ids = try names.map { name in
                try start.addFavorite(
                    title: name, url: DesignTests.url(name.replacingOccurrences(of: " ", with: "")), in: page)
            }
            _ = try await DesignTests.until {
                let look = try start.startScreen(of: page)
                return look.linkTitles.count == 6 && look.bounds.width > 800
            }
            let look = try await shown()
            try await design.writeScreenshot(of: page, to: folder.appendingPathComponent("6-start-screen.png"))
            return (ids, look)
        }
        // The parts sit 26 points apart, centred in the card.
        let full = added.1
        run.check(
            "design.start_layout",
            passed: full.gaps.count == 4 && full.gaps.allSatisfy { abs($0 - 26) < 0.5 }
                && abs(full.contentFrame.midX - full.bounds.midX) < 1
                && abs(full.contentFrame.midY - full.bounds.midY) < 1 && full.linkTitles.count == 6,
            "gaps=\(full.gaps) content=\(full.contentFrame) bounds=\(full.bounds) links=\(full.linkTitles.count)")

        let narrow = try await run.step("narrow the window", timeout: E2ETimeouts.step) {
            try design.resizeWindow(of: page, width: 640, height: 560)
            _ = try await DesignTests.until { try start.startScreen(of: page).bounds.width < 400 }
            let look = try start.startScreen(of: page)
            try await design.writeScreenshot(of: page, to: folder.appendingPathComponent("7-start-narrow.png"))
            try design.resizeWindow(of: page, width: 1200, height: 800)
            return look
        }
        run.check(
            "design.start_narrow",
            passed: narrow.bounds.width < 400 && narrow.contentFrame.minX >= 24
                && narrow.contentFrame.maxX <= narrow.bounds.maxX - 24 && narrow.pillFrame.width < 560
                && narrow.pillFrame.width > 0 && narrow.linkTitles.count < 6,
            "bounds=\(narrow.bounds) content=\(narrow.contentFrame) pill=\(narrow.pillFrame.width)"
                + " links=\(narrow.linkTitles.count)")

        let dark = try await run.step("switch to dark", timeout: E2ETimeouts.step) {
            try design.setDarkAppearance(true, of: page)
            _ = try await DesignTests.until { try design.look(of: page).frameColor == DesignTests.frameDark }
            try await design.writeScreenshot(of: page, to: folder.appendingPathComponent("8-start-dark.png"))
            let look = try start.startScreen(of: page)
            try design.setDarkAppearance(false, of: page)
            return look
        }
        run.check(
            "design.start_dark",
            passed: dark.isShown && !dark.drawsDark && dark.pillFill == "#FFFFFF"
                && dark.greetingColor == DesignTests.textLight,
            "shown=\(dark.isShown) draws_dark=\(dark.drawsDark) pill=\(dark.pillFill ?? "none")"
                + " greeting=\(dark.greetingColor ?? "none")")

        // Deleting the first Favorite while the screen shows moves the seventh in; a quick link shows its Favorite.
        let ids = added.0
        let afterDelete = try await run.step("delete the first Favorite", timeout: E2ETimeouts.step) {
            try start.deleteFavorite(ids[0], in: page)
            _ = try await DesignTests.until { try start.startScreen(of: page).linkTitles.first == names[1] }
            return try start.startScreen(of: page)
        }
        let clicked = try await run.step("click a quick link", timeout: E2ETimeouts.firstLoad) {
            try start.clickQuickLink(1, in: page)
            _ = try await DesignTests.until {
                let state = try edges.windowState(of: page)
                return state.activeItem == ids[2] && state.showsPage
            }
            return (try edges.windowState(of: page), try start.startScreen(of: page).isShown)
        }
        run.check(
            "design.start_links",
            passed: first.linkTitles.isEmpty && full.linkTitles == Array(names.prefix(6))
                && afterDelete.linkTitles == Array(names.dropFirst())
                && full.tileSize == CGSize(width: 56, height: 56) && full.tileRadius == 16
                && full.linkFrame.width == 76 && full.tileFill == "#FFFFFF" && full.linkTitleFont?.size == 12.5
                && clicked.0.activeItem == ids[2] && clicked.0.showsPage && !clicked.1,
            "none=\(first.linkTitles) six=\(full.linkTitles) after_delete=\(afterDelete.linkTitles)"
                + " tile=\(full.tileSize) radius=\(full.tileRadius) link=\(full.linkFrame.width)"
                + " fill=\(full.tileFill ?? "none") title_font=\(String(describing: full.linkTitleFont))"
                + " active=\(clicked.0.activeItem ?? "none") page=\(clicked.0.showsPage) start_after=\(clicked.1)")
    }
}
