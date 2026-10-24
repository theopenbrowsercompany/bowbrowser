import Foundation

/// The start screen of an empty Space (the styling guide's first mockup): the Bow mark at 64, the greeting for the
/// hour the app read (Fredoka 600 at 40), the 560 by 52 search pill that opens the command bar as Cmd+T does, the
/// profile's first six Favorites as quick links and the hint naming the Space in 13 point Nunito Sans, 26 points
/// apart. Also: no Favorites hides the row, a Favorite deleted while the screen shows leaves it, a quick link opens
/// its Favorite, switching between empty Spaces renames the hint, a long name is cut, a narrow window keeps
/// everything inside the card, and in the dark appearance the screen still draws light on the White card.
@MainActor
enum DesignStartScreenTests {
    static let all: [any E2ETest] = [DesignStartScreenTest()]
}

struct DesignStartScreenTest: E2ETest {
    let name = "design.start_screen"
    let checks = [
        "design.empty_mark", "design.fonts_empty", "design.start_greeting", "design.start_hint", "design.start_search",
        "design.start_links", "design.start_layout", "design.start_narrow", "design.start_dark",
    ]

    /// The greeting the styling guide gives for a local hour: morning 5 to 12, afternoon 12 to 18, else evening.
    static func greeting(for hour: Int) -> String {
        switch hour {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    static func hint(_ space: String) -> String {
        "\(space) \u{00B7} press \u{2318}T to search"
    }

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let edges = run.app as? any E2EWindowEdgesApp, let start = run.app as? any E2EStartScreenApp,
            let seeds = run.app as? any E2EStoreSeedApp, let bars = run.app as? any E2ECommandBarApp,
            let fonts = run.app as? any E2EFontsApp
        else { throw E2EError("the app lacks the window edges, start screen, seed, command bar or font hooks") }
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let seed = E2ESeed(spaces: [E2ESeedSpace("Home", today: [.tab("Reading", url: DesignTests.url("Reading"))])]
            )
            let window = try await seeds.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        func shown() async throws -> E2EStartScreenLook {
            _ = try await E2EWaits.until { try start.startScreen(of: page).isShown }
            let look = try start.startScreen(of: page)
            guard look.isShown else { throw E2EError("the start screen is not shown") }
            return look
        }

        // An empty Space of the same profile, which has no Favorites yet.
        let opened = try await run.step("switch to an empty Space", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            try start.renameActiveSpace("Work Space", in: page)
            _ = try await E2EWaits.until { try start.startScreen(of: page).hint.hasPrefix("Work Space") }
            let screen = try await shown()
            return (screen, try design.look(of: page).frame, try fonts.fonts(of: page))
        }
        let first = opened.0
        let empty = opened.1
        run.check(
            "design.empty_mark", passed: empty.showsEmptyState && empty.emptyStateMarkSize >= 24,
            "empty=\(empty.showsEmptyState) mark=\(empty.emptyStateMarkSize)")
        // The start screen's hint is 13 point Nunito Sans.
        run.check(
            "design.fonts_empty",
            passed: opened.2.emptyStateLine?.family == "Nunito Sans" && opened.2.emptyStateLine?.size == 13,
            "line=\(String(describing: opened.2.emptyStateLine))")
        let expectedGreeting = Self.greeting(for: first.greetingHour)
        // The app read the local hour (or the one before it, when the hour turned since).
        let hourNow = Calendar.current.component(.hour, from: Date())
        let localHour = first.greetingHour == hourNow || first.greetingHour == (hourNow + 23) % 24
        run.check(
            "design.start_greeting",
            passed: first.greeting == expectedGreeting && localHour
                && first.greetingFont?.family == "Fredoka" && first.greetingFont?.name.contains("SemiBold") == true
                && first.greetingFont?.size == 40 && first.greetingColor == DesignTests.textLight
                && first.markSize == CGSize(width: 64, height: 64),
            "greeting=\"\(first.greeting)\" hour=\(first.greetingHour) now=\(hourNow) expected=\"\(expectedGreeting)\""
                + " font=\(String(describing: first.greetingFont)) color=\(first.greetingColor ?? "none")"
                + " mark=\(first.markSize)")

        // Another empty Space while the screen shows, then a name too long to show whole.
        let second = try await run.step("switch to a second empty Space with a long name", timeout: E2ETimeouts.step) {
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            try start.renameActiveSpace("Side", in: page)
            _ = try await E2EWaits.until { try start.startScreen(of: page).hint == Self.hint("Side") }
            let side = try start.startScreen(of: page)
            try start.renameActiveSpace(String(repeating: "Long ", count: 20), in: page)
            _ = try await E2EWaits.until { try start.startScreen(of: page).hint.contains("\u{2026}") }
            return (side, try start.startScreen(of: page))
        }
        let long = second.1
        run.check(
            "design.start_hint",
            passed: first.hint == Self.hint("Work Space") && second.0.hint == Self.hint("Side")
                && long.hint.hasSuffix("\u{2026} \u{00B7} press \u{2318}T to search")
                && long.contentFrame.minX >= long.bounds.minX && long.contentFrame.maxX <= long.bounds.maxX
                && first.hintFont?.family == "Nunito Sans" && first.hintFont?.size == 13
                && first.hintColor == "#7A5A48",
            "first=\"\(first.hint)\" second=\"\(second.0.hint)\" long=\"\(long.hint)\""
                + " font=\(String(describing: first.hintFont)) color=\(first.hintColor ?? "none")")

        let searched = try await run.step("click the search pill", timeout: E2ETimeouts.step) {
            let bar = try bars.commandBar(of: page)
            try start.clickStartSearch(in: page)
            _ = try await E2EWaits.until { bar.isShown }
            let result = (bar.isShown, bar.text)
            if bar.isShown {
                try bar.press(.escape)
                _ = try await E2EWaits.until { !bar.isShown }
            }
            return result
        }
        run.check(
            "design.start_search",
            passed: searched.0 && searched.1.isEmpty && first.pillFrame.size == CGSize(width: 560, height: 52)
                && first.pillRadius == 26 && first.pillFill == "#FFFFFF" && first.pillBorder == "#F0DCC8"
                && first.pillBorderWidth == 1 && first.placeholder == "Search or type a URL"
                && first.placeholderFont?.family == "Nunito Sans" && first.placeholderFont?.size == 16,
            "bar_shown=\(searched.0) text=\"\(searched.1)\" pill=\(first.pillFrame.size) radius=\(first.pillRadius)"
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
                    title: name,
                    url: E2EFixture.url("design/page.html?title=\(name.replacingOccurrences(of: " ", with: ""))"),
                    in: page)
            }
            _ = try await E2EWaits.until {
                let look = try start.startScreen(of: page)
                return look.linkTitles.count == 6 && look.bounds.width > 800
            }
            let look = try await shown()
            await E2EDesignFixture.capture(run, page, .window, "start-screen")
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
            _ = try await E2EWaits.until { try start.startScreen(of: page).bounds.width < 400 }
            let look = try start.startScreen(of: page)
            await E2EDesignFixture.capture(run, page, .window, "start-narrow")
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
            _ = try await E2EWaits.until { try design.look(of: page).frame.frameColor == DesignTests.frameDark }
            await E2EDesignFixture.capture(run, page, .window, "start-dark")
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
            _ = try await E2EWaits.until { try start.startScreen(of: page).linkTitles.first == names[1] }
            return try start.startScreen(of: page)
        }
        let clicked = try await run.step("click a quick link", timeout: E2ETimeouts.firstLoad) {
            try start.clickQuickLink(1, in: page)
            _ = try await E2EWaits.until {
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
