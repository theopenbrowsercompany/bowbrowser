import Foundation

/// Spaces: switching with the menu shortcuts and the switcher, swiping, and creating, renaming and deleting them.
@MainActor
enum SpacesAreaTests {
    static let all: [any E2ETest] = [SpacesSwitchTest(), SpacesSwipeTest(), SpacesManageTest(), SpacesThemeTest()]

    static func url(_ name: String) -> URL { E2EFixture.url("sidebar/page.html?name=\(name)") }

    static func app(of run: E2ERun) throws -> any E2ESpacesApp & E2EStoreSeedApp {
        guard let app = run.app as? any E2ESpacesApp & E2EStoreSeedApp else {
            throw E2EError("the app cannot drive Spaces")
        }
        return app
    }

    /// Opens a window on Spaces "work" (today tabs A and B) and "personal" (today tab C), with "work" on screen, and
    /// waits for its sidebar to list A and B.
    static func openWorkAndPersonal(_ run: E2ERun, app: any E2ESpacesApp & E2EStoreSeedApp) async throws
        -> any E2EPage
    {
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace("work", today: [.tab("A", url: url("A")), .tab("B", url: url("B"))]),
                E2ESeedSpace("personal", today: [.tab("C", url: url("C"))]),
            ],
            activeSpace: "work")
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        _ = try await run.step("work lists A and B", timeout: E2ETimeouts.step) {
            try await settle(app, page) { $0.tabs == ["A", "B"] }
        }
        return page
    }

    /// The window's Spaces once `done` holds, or as they read last shortly before the step's limit.
    static func settle(_ app: any E2ESpacesApp, _ page: any E2EPage, until done: (E2ESpacesState) -> Bool)
        async throws -> E2ESpacesState
    {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while true {
            let state = try app.spaces(of: page)
            if done(state) || Date() >= deadline { return state }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Returns once the window `page` is in shows no sheet, or shortly before the step's limit.
    static func sheetClosed(_ app: any E2ESpacesApp, _ page: any E2EPage) async throws {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while try app.sheetMessage(in: page) != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The window's Spaces a moment after an action that should change nothing.
    static func unchanged(_ app: any E2ESpacesApp, _ page: any E2EPage) async throws -> E2ESpacesState {
        try await Task.sleep(nanoseconds: 200_000_000)
        return try app.spaces(of: page)
    }

    /// Runs `body` and returns "ok", or what it threw. The test's end and cancellation still end the test.
    static func outcome(_ body: () throws -> Void) throws -> String {
        do {
            try body()
            return "ok"
        } catch let error as E2EError where error.reason == .testEnded {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            return "\(error)"
        }
    }
}

/// Seeds "work" (A, B) and "personal" (C) and switches through the menu: Ctrl+2 shows personal with only C in the
/// one window, Ctrl+1 shows work again with only A and B, and Ctrl+5 (no fifth Space) is disabled and changes
/// nothing. Cmd+Option+Right and Left move one Space at a time and stop at the last and first. The sidebar's header
/// shows the name of the Space on screen and its footer an icon per Space with that one highlighted.
struct SpacesSwitchTest: E2ETest {
    let name = "spaces.switch"
    let tags = ["smoke"]
    let checks = ["spaces.switch", "spaces.shortcuts", "spaces.arrows", "spaces.switcher"]

    func run(_ run: E2ERun) async throws {
        let app = try SpacesAreaTests.app(of: run)
        let page = try await SpacesAreaTests.openWorkAndPersonal(run, app: app)

        let personal = try await run.step("Ctrl+2", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "2", modifiers: .control, in: page)
            return try await SpacesAreaTests.settle(app, page) { $0.active == "personal" && $0.tabs == ["C"] }
        }
        run.check(
            "spaces.switch", passed: personal.windows == 1 && personal.active == "personal" && personal.tabs == ["C"],
            "windows=\(personal.windows) active=\(personal.active) tabs=[\(personal.tabs.joined(separator: ","))]")

        let shortcuts = try await run.step("Ctrl+1 then Ctrl+5", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "1", modifiers: .control, in: page)
            let work = try await SpacesAreaTests.settle(app, page) { $0.active == "work" && $0.tabs == ["A", "B"] }
            let title = app.menuItemTitle(key: "1", modifiers: .control) ?? "none"
            let five = try SpacesAreaTests.outcome { try app.chooseMenuItem(key: "5", modifiers: .control, in: page) }
            let after = try await SpacesAreaTests.unchanged(app, page)
            return (work, title, five, after)
        }
        run.check(
            "spaces.shortcuts",
            passed: shortcuts.0.active == "work" && shortcuts.0.tabs == ["A", "B"] && shortcuts.1 == "work"
                && shortcuts.2.contains("disabled") && shortcuts.3 == shortcuts.0,
            "ctrl1=\(shortcuts.0.active) tabs=[\(shortcuts.0.tabs.joined(separator: ","))] item1=\(shortcuts.1) "
                + "ctrl5=\(shortcuts.2.contains("disabled") ? "disabled" : shortcuts.2) "
                + "after=\(shortcuts.3.active) windows=\(shortcuts.3.windows)")

        let arrows = try await run.step("Cmd+Option+Right and Left", timeout: E2ETimeouts.step) {
            var seen: [String] = []
            try app.chooseMenuItem(key: E2EMenuKey.rightArrow, modifiers: [.command, .option], in: page)
            seen.append(try await SpacesAreaTests.settle(app, page) { $0.active == "personal" }.active)
            let pastLast = try SpacesAreaTests.outcome {
                try app.chooseMenuItem(key: E2EMenuKey.rightArrow, modifiers: [.command, .option], in: page)
            }
            seen.append(try await SpacesAreaTests.unchanged(app, page).active)
            try app.chooseMenuItem(key: E2EMenuKey.leftArrow, modifiers: [.command, .option], in: page)
            seen.append(try await SpacesAreaTests.settle(app, page) { $0.active == "work" }.active)
            let pastFirst = try SpacesAreaTests.outcome {
                try app.chooseMenuItem(key: E2EMenuKey.leftArrow, modifiers: [.command, .option], in: page)
            }
            let last = try await SpacesAreaTests.unchanged(app, page)
            seen.append(last.active)
            return (seen, pastLast.contains("disabled"), pastFirst.contains("disabled"), last.windows)
        }
        run.check(
            "spaces.arrows",
            passed: arrows.0 == ["personal", "personal", "work", "work"] && arrows.1 && arrows.2 && arrows.3 == 1,
            "seen=[\(arrows.0.joined(separator: ","))] past-last=\(arrows.1 ? "disabled" : "enabled") "
                + "past-first=\(arrows.2 ? "disabled" : "enabled") windows=\(arrows.3)")

        let switcher = try await run.step("the switcher shows the Space on screen", timeout: E2ETimeouts.step) {
            try await SpacesAreaTests.settle(app, page) { $0.header == "work" && $0.footer == ["work*", "personal"] }
        }
        run.check(
            "spaces.switcher", passed: switcher.header == "work" && switcher.footer == ["work*", "personal"],
            "header=\(switcher.header) footer=[\(switcher.footer.joined(separator: ","))]")
    }
}

/// Drives the sidebar's swipe handler directly, since a real trackpad gesture cannot be synthesized: a swipe towards
/// the next Space shows personal, another on the last Space changes nothing, a short one changes nothing, and a
/// swipe back shows work again, all in one window.
struct SpacesSwipeTest: E2ETest {
    let name = "spaces.swipe"

    func run(_ run: E2ERun) async throws {
        let app = try SpacesAreaTests.app(of: run)
        let page = try await SpacesAreaTests.openWorkAndPersonal(run, app: app)
        let seen = try await run.step("swipe between Spaces", timeout: E2ETimeouts.step) {
            var seen: [String] = []
            try app.swipeSidebar(.towardsNext, distance: 120, in: page)
            seen.append(try await SpacesAreaTests.settle(app, page) { $0.active == "personal" }.active)
            try app.swipeSidebar(.towardsNext, distance: 120, in: page)
            seen.append(try await SpacesAreaTests.unchanged(app, page).active)
            try app.swipeSidebar(.towardsPrevious, distance: 10, in: page)
            seen.append(try await SpacesAreaTests.unchanged(app, page).active)
            try app.swipeSidebar(.towardsPrevious, distance: 120, in: page)
            let back = try await SpacesAreaTests.settle(app, page) { $0.active == "work" && $0.tabs == ["A", "B"] }
            seen.append(back.active)
            return (seen, back)
        }
        run.check(
            "spaces.swipe",
            passed: seen.0 == ["personal", "personal", "personal", "work"] && seen.1.tabs == ["A", "B"]
                && seen.1.windows == 1,
            "next,next-at-last,short,previous=[\(seen.0.joined(separator: ","))] "
                + "tabs=[\(seen.1.tabs.joined(separator: ","))] windows=\(seen.1.windows)")
    }
}

/// Creates a Space with the switcher's "+" and another from View > Spaces > New Space, renames one in the rename
/// sheet, deletes an empty Space at once, deletes "work" (which has a tab) only after confirming in a sheet (Cancel
/// keeps it), and finds Delete Space disabled for the last Space.
struct SpacesManageTest: E2ETest {
    let name = "spaces.manage"
    let checks = [
        "spaces.create", "spaces.create-menu", "spaces.rename", "spaces.delete-empty", "spaces.delete-confirm",
        "spaces.last",
    ]

    func run(_ run: E2ERun) async throws {
        let app = try SpacesAreaTests.app(of: run)
        let seed = E2ESeed(spaces: [E2ESeedSpace("work", today: [.tab("A", url: SpacesAreaTests.url("A"))])])
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }

        let created = try await run.step("the + button", timeout: E2ETimeouts.step) {
            try app.clickNewSpaceButton(in: page)
            return try await SpacesAreaTests.settle(app, page) { $0.spaces.count == 2 && $0.header == "Space 2" }
        }
        run.check(
            "spaces.create",
            passed: created.spaces == ["work", "Space 2"] && created.active == "Space 2" && created.tabs.isEmpty
                && created.header == "Space 2" && created.footer == ["work", "Space 2*"],
            "\(created)")

        let fromMenu = try await run.step("View > Spaces > New Space", timeout: E2ETimeouts.step) {
            try app.chooseSpacesMenuItem("New Space", in: page)
            return try await SpacesAreaTests.settle(app, page) { $0.spaces.count == 3 }
        }
        run.check(
            "spaces.create-menu",
            passed: fromMenu.spaces == ["work", "Space 2", "Space 3"] && fromMenu.active == "Space 3"
                && fromMenu.windows == 1,
            "spaces=[\(fromMenu.spaces.joined(separator: ","))] active=\(fromMenu.active) windows=\(fromMenu.windows)")

        let renamed = try await run.step("rename Space 3 to personal", timeout: E2ETimeouts.step) {
            try app.chooseSpacesMenuItem("Rename Space…", in: page)
            let message = try app.sheetMessage(in: page) ?? "no sheet"
            try app.answerSheet("Rename", text: "  personal ", in: page)
            let state = try await SpacesAreaTests.settle(app, page) {
                $0.active == "personal" && $0.header == "personal"
            }
            try await SpacesAreaTests.sheetClosed(app, page)
            return (message, state, try app.sheetMessage(in: page))
        }
        run.check(
            "spaces.rename",
            passed: renamed.0.contains("Rename Space") && renamed.1.spaces == ["work", "Space 2", "personal"]
                && renamed.1.header == "personal" && renamed.2 == nil,
            "sheet=\(renamed.0.contains("Rename Space") ? "Rename Space" : renamed.0) "
                + "spaces=[\(renamed.1.spaces.joined(separator: ","))] header=\(renamed.1.header)")

        let deletedEmpty = try await run.step("delete the empty Space 2", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "2", modifiers: .control, in: page)
            _ = try await SpacesAreaTests.settle(app, page) { $0.active == "Space 2" }
            try app.chooseSpacesMenuItem("Delete Space…", in: page)
            let sheet = try app.sheetMessage(in: page)
            let state = try await SpacesAreaTests.settle(app, page) { $0.spaces.count == 2 }
            return (sheet, state)
        }
        run.check(
            "spaces.delete-empty",
            passed: deletedEmpty.0 == nil && deletedEmpty.1.spaces == ["work", "personal"]
                && deletedEmpty.1.active == "personal",
            "sheet=\(deletedEmpty.0 ?? "none") spaces=[\(deletedEmpty.1.spaces.joined(separator: ","))] "
                + "active=\(deletedEmpty.1.active)")

        let confirmed = try await run.step("delete work after confirming", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "1", modifiers: .control, in: page)
            _ = try await SpacesAreaTests.settle(app, page) { $0.active == "work" }
            try app.chooseSpacesMenuItem("Delete Space…", in: page)
            let message = try app.sheetMessage(in: page) ?? "no sheet"
            try app.answerSheet("Cancel", text: nil, in: page)
            try await SpacesAreaTests.sheetClosed(app, page)
            let kept = try app.spaces(of: page)
            try app.chooseSpacesMenuItem("Delete Space…", in: page)
            try app.answerSheet("Delete", text: nil, in: page)
            let state = try await SpacesAreaTests.settle(app, page) { $0.spaces == ["personal"] }
            try await SpacesAreaTests.sheetClosed(app, page)
            return (message, kept, state)
        }
        let asked = confirmed.0.contains("Delete “work”?") && confirmed.0.contains("tab closes")
        run.check(
            "spaces.delete-confirm",
            passed: asked && confirmed.1.spaces == ["work", "personal"] && confirmed.2.spaces == ["personal"]
                && confirmed.2.active == "personal" && confirmed.2.windows == 1,
            "asked=\(asked ? "Delete “work”?" : confirmed.0) cancel-kept=[\(confirmed.1.spaces.joined(separator: ","))] "
                + "after=[\(confirmed.2.spaces.joined(separator: ","))] active=\(confirmed.2.active)")

        let last = try await run.step("the last Space cannot be deleted", timeout: E2ETimeouts.step) {
            let refused = try SpacesAreaTests.outcome { try app.chooseSpacesMenuItem("Delete Space…", in: page) }
            return (refused, try await SpacesAreaTests.unchanged(app, page))
        }
        run.check(
            "spaces.last", passed: last.0.contains("disabled") && last.1.spaces == ["personal"],
            "delete=\(last.0.contains("disabled") ? "disabled" : last.0) spaces=[\(last.1.spaces.joined(separator: ","))]"
        )
    }
}

/// Seeds "work" (A, B) and "personal" (C) and themes "work" from its Space menu: Theme > Blue and the icon 💼 (a
/// two letter icon is refused with a message). The window's background, and the sidebar drawn over it, take a 12
/// percent wash of the blue over the Frame color; switching to "personal" fades back to the plain Frame color, and
/// three quick switches end on the right tint. In dark appearance the wash goes over the dark Frame color, and
/// Theme > Default while "work" is on screen removes it. Screenshots go to `<run>/spaces/`.
struct SpacesThemeTest: E2ETest {
    let name = "spaces.theme"
    let checks = ["spaces.theme_menu", "spaces.theme_tint", "spaces.theme_switch", "spaces.theme_dark"]

    /// The Frame colors, and #3B5BDB at 12 percent over them.
    static let frameLight = "#FFF3E6"
    static let frameDark = "#2A1710"
    static let blueLight = "#E7E1E5"
    static let blueDark = "#2C1F28"

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2ESpaceThemeApp & E2EStoreSeedApp, let design = run.app as? any E2EDesignApp
        else { throw E2EError("the app cannot drive Space themes") }
        let page = try await SpacesAreaTests.openWorkAndPersonal(run, app: app)
        let folder = run.dataDirectory.deletingLastPathComponent().appendingPathComponent("spaces", isDirectory: true)
        func settled(_ done: @escaping (E2ESpaceTheme) -> Bool) async throws -> E2ESpaceTheme {
            let deadline = Date().addingTimeInterval(E2EWaits.budget())
            while true {
                let theme = try app.spaceTheme(of: page)
                if (done(theme) && !theme.animating) || Date() >= deadline { return theme }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        let menu = try await run.step("theme and icon from the Space menu", timeout: E2ETimeouts.step) {
            let before = try app.spaceMenuTitles(in: page)
            try app.chooseSpaceMenuItem(["Theme", "Blue"], in: page)
            let fading = try app.spaceTheme(of: page)
            try app.chooseSpaceMenuItem(["Change Icon…"], in: page)
            let asked = try app.sheetMessage(in: page) ?? "no sheet"
            try app.answerSheet("Set Icon", text: "💼", in: page)
            _ = try await SpacesAreaTests.settle(app, page) { $0.header == "💼 work" }
            try await SpacesAreaTests.sheetClosed(app, page)
            try app.chooseSpaceMenuItem(["Change Icon…"], in: page)
            try app.answerSheet("Set Icon", text: "ab", in: page)
            let refusal = try await refusalMessage(app, page)
            if refusal != nil { try app.answerSheet("OK", text: nil, in: page) }
            try await SpacesAreaTests.sheetClosed(app, page)
            let after = try app.spaceMenuTitles(in: page)
            return (before, fading, asked, refusal, after, try app.spaceTheme(of: page), try app.spaces(of: page))
        }
        let offered =
            ["Theme", "Theme/Default*"]
            + ["Blue", "Jam", "Apricot", "Cocoa", "Green", "Brick"].map {
                "Theme/\($0)"
            } + ["Change Icon…", "Remove Icon!"]
        let menuOK =
            menu.0.suffix(offered.count) == offered[...] && (menu.1.animating || menu.1.reduceMotion)
            && menu.2.contains("Change Icon") && menu.3?.contains("is not a single emoji") == true
            && menu.4.contains("Theme/Blue*") && menu.4.contains("Remove Icon") && menu.5.icons == ["💼", "-"]
            && menu.5.themes == ["#3B5BDB", "default"] && menu.6.header == "💼 work"
        run.check(
            "spaces.theme_menu", passed: menuOK,
            "menu=[\(menu.0.joined(separator: ","))] faded=\(menu.1.animating) refused=\(menu.3 ?? "none") "
                + "after=[\(menu.4.joined(separator: ","))] \(menu.5) header=\(menu.6.header)")

        let tint = try await run.step("work's tint", timeout: E2ETimeouts.step) {
            let theme = try await settled { $0.background == Self.blueLight }
            let drawn = try app.sidebarDrawnColor(of: page)
            try await design.writeScreenshot(of: page, to: folder.appendingPathComponent("theme-work.png"))
            return (theme, drawn)
        }
        let tintMatches = tint.0.background == Self.blueLight && Self.near(tint.1, Self.blueLight)
        run.check(
            "spaces.theme_tint", passed: tintMatches && tint.0.activeTheme == "#3B5BDB",
            "work=\(tint.0.activeTheme) tint_matches=\(tintMatches)"
                + (tintMatches ? "" : " background=\(tint.0.background) drawn=\(tint.1)"))

        let switched = try await run.step("switch away and back quickly", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "2", modifiers: .control, in: page)
            let fading = try app.spaceTheme(of: page)
            let personal = try await settled { $0.background == Self.frameLight }
            let drawn = try app.sidebarDrawnColor(of: page)
            try app.chooseMenuItem(key: "1", modifiers: .control, in: page)
            try app.chooseMenuItem(key: "2", modifiers: .control, in: page)
            try app.chooseMenuItem(key: "1", modifiers: .control, in: page)
            let back = try await settled { $0.background == Self.blueLight }
            return (fading, personal, drawn, back)
        }
        run.check(
            "spaces.theme_switch",
            passed: (switched.0.animating || switched.0.reduceMotion) && switched.1.activeTheme == "#8E96A8"
                && switched.1.background == Self.frameLight && Self.near(switched.2, Self.frameLight)
                && switched.3.background == Self.blueLight && switched.3.activeTheme == "#3B5BDB",
            "faded=\(switched.0.animating) personal=\(switched.1.background) drawn=\(switched.2) "
                + "back=\(switched.3.background) animating=\(switched.3.animating)")

        let dark = try await run.step("dark, then Theme > Default", timeout: E2ETimeouts.step) {
            try design.setDarkAppearance(true, of: page)
            let tinted = try await settled { $0.dark && $0.background == Self.blueDark }
            let drawn = try app.sidebarDrawnColor(of: page)
            try await design.writeScreenshot(of: page, to: folder.appendingPathComponent("theme-dark.png"))
            try app.chooseSpaceMenuItem(["Theme", "Default"], in: page)
            let plain = try await settled { $0.background == Self.frameDark }
            try design.setDarkAppearance(false, of: page)
            return (tinted, drawn, plain)
        }
        run.check(
            "spaces.theme_dark",
            passed: dark.0.background == Self.blueDark && Self.near(dark.1, Self.blueDark)
                && dark.2.background == Self.frameDark && dark.2.themes == ["default", "default"]
                && dark.2.icons == ["💼", "-"],
            "dark=\(dark.0.background) drawn=\(dark.1) default=\(dark.2.background) themes=[\(dark.2.themes.joined(separator: ","))]"
        )
    }

    /// The message of the sheet that refuses an icon, once the icon sheet has given way to it; nil when none comes.
    private func refusalMessage(_ app: any E2ESpacesApp, _ page: any E2EPage) async throws -> String? {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while Date() < deadline {
            if let message = try app.sheetMessage(in: page), message.contains("is not") { return message }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    /// Whether two `#RRGGBB` colors differ by at most 3 in every channel (drawing may round on the way).
    static func near(_ a: String, _ b: String) -> Bool {
        func channels(_ hex: String) -> [Int]? {
            let digits = Array(hex.dropFirst())
            guard hex.first == "#", digits.count == 6 else { return nil }
            return stride(from: 0, to: 6, by: 2).compactMap { Int(String(digits[$0..<$0 + 2]), radix: 16) }
        }
        guard let left = channels(a), let right = channels(b), left.count == 3, right.count == 3 else { return false }
        return zip(left, right).allSatisfy { abs($0 - $1) <= 3 }
    }
}
