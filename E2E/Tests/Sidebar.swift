import Foundation

/// Tests of the vertical sidebar: it lists the window's tabs with icon and title, highlights the active one, and
/// its rows, close buttons and New Tab button drive the tabs. Fixtures in E2E/Fixtures/sidebar/.
@MainActor
enum SidebarViewTests {
    static let all: [any E2ETest] = [
        SidebarTabsTest(), SidebarLongTitleTest(), SidebarMenuShortcutsTest(), SidebarSeedTest(),
    ]
}

/// Waits on the sidebar shared by the sidebar and tab list tests.
@MainActor
enum SidebarWaits {
    static func app(_ run: E2ERun) throws -> any E2ESidebarApp {
        guard let app = run.app as? any E2ESidebarApp else { throw E2EError("the app has no sidebar to drive") }
        return app
    }

    /// The sidebar rows of `page`'s window once `condition` holds for them. The sidebar changes on the engine's
    /// main thread tasks, so this checks once per run loop turn; a condition that never holds runs into the step
    /// timeout.
    @discardableResult
    static func rows(
        _ app: any E2ESidebarApp,
        of page: any E2EPage,
        until condition: ([E2ESidebarRow]) -> Bool
    ) async throws -> [E2ESidebarRow] {
        while true {
            let rows = try app.sidebarRows(of: page)
            if condition(rows) { return rows }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// "tabs=[A,B] active=B" for `rows`.
    static func summary(_ rows: [E2ESidebarRow]) -> String {
        let active = rows.filter(\.isActive).map(\.title).joined(separator: ",")
        return "tabs=[\(rows.map(\.title).joined(separator: ","))] active=\(active.isEmpty ? "none" : active)"
    }

    /// Waits until a page just shown counts as visible, which Chromium reports a moment after the view is attached,
    /// then until it paints. A page that stays hidden runs into the step timeout.
    static func untilShown(_ page: any E2EPage) async throws {
        _ = try await page.evaluate(
            """
            new Promise(resolve => {
              if (document.visibilityState === "visible") return resolve(true);
              document.addEventListener("visibilitychange", function listener() {
                if (document.visibilityState !== "visible") return;
                document.removeEventListener("visibilitychange", listener);
                resolve(true);
              });
            })
            """
        )
        try await E2EWaits.untilRendering(page)
    }
}

/// Opens tab A, then tab B with the New Tab button, and checks the sidebar lists both with their icons and titles
/// and highlights B; that it followed B's loading state and a title change; and that clicking each row shows its
/// page without reloading it. Then closes a tab with its row's close button and another with Command-W.
struct SidebarTabsTest: E2ETest {
    let name = "sidebar.tabs"
    let tags = ["smoke"]
    let checks = ["sidebar.tabs", "sidebar.close"]

    func run(_ run: E2ERun) async throws {
        let app = try SidebarWaits.app(run)
        let a = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("sidebar/page.html?name=A"))
        }
        try await run.step("load A", timeout: E2ETimeouts.firstLoad) {
            _ = try await a.waitForLoad(after: 0)
        }
        let b = try await run.step("new tab B", timeout: E2ETimeouts.firstLoad) {
            let b = try app.clickNewTab(besides: a, opening: E2EFixture.url("sidebar/page.html?name=B"))
            _ = try await b.waitForLoad(after: 0)
            return b
        }

        var problems: [String] = []
        try await run.step("sidebar lists A and B", timeout: E2ETimeouts.step) {
            try await SidebarWaits.rows(app, of: a) { rows in
                rows.map(\.title) == ["A", "B"] && rows.allSatisfy { $0.hasFavicon && !$0.isLoading }
                    && rows.map(\.isActive) == [false, true]
            }
            // The row followed B's page: a spinner while it loaded, then its title once it stopped.
            let history = app.sidebarRowHistory(of: b)
            guard let loading = history.firstIndex(where: \.isLoading),
                history[loading...].contains(where: { !$0.isLoading && $0.title == "B" })
            else {
                problems.append("B's row went \(history.map(\.description).joined(separator: " > "))")
                return
            }
        }
        try await run.step("title change", timeout: E2ETimeouts.step) {
            _ = try await b.evaluate("document.title = 'B renamed'")
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B renamed"] }
            _ = try await b.evaluate("document.title = 'B'")
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B"] }
        }
        let loadIDs = try await run.step("record pages", timeout: E2ETimeouts.step) {
            [try await a.string("window.bowLoadID"), try await b.string("window.bowLoadID")]
        }
        try await run.step("click rows", timeout: E2ETimeouts.step) {
            for (page, label) in [(a, "A"), (b, "B")] {
                try app.clickSidebarRow(of: page)
                guard page.isShown else {
                    problems.append("clicking \(label) did not show it")
                    continue
                }
                try await SidebarWaits.rows(app, of: a) { $0.first(where: \.isActive)?.title == label }
                try await SidebarWaits.untilShown(page)
            }
            for (page, loadID, label) in [(a, loadIDs[0], "A"), (b, loadIDs[1], "B")] {
                if try await page.string("window.bowLoadID") != loadID || page.finishedLoads != 1 {
                    problems.append("\(label) reloaded")
                }
            }
        }
        let rows = try app.sidebarRows(of: a)
        let summary = SidebarWaits.summary(rows)
        let detail = problems.isEmpty ? summary : "\(summary) \(problems.joined(separator: "; "))"
        run.check(name, passed: problems.isEmpty && summary == "tabs=[A,B] active=B", detail)

        let button = try await run.step("close with the button", timeout: E2ETimeouts.firstLoad) {
            let c = try app.clickNewTab(besides: a, opening: E2EFixture.url("sidebar/page.html?name=C"))
            _ = try await c.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B", "C"] }
            try app.clickSidebarClose(of: c)
            while !c.isClosed { try await Task.sleep(nanoseconds: 10_000_000) }
            return SidebarWaits.summary(try await SidebarWaits.rows(app, of: a) { $0.count == 2 })
        }
        let commandW = try await run.step("close with Command-W", timeout: E2ETimeouts.firstLoad) {
            let d = try app.clickNewTab(besides: a, opening: E2EFixture.url("sidebar/page.html?name=D"))
            _ = try await d.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B", "D"] }
            try app.chooseMenuItem(commandKey: "w", in: d)
            while !d.isClosed { try await Task.sleep(nanoseconds: 10_000_000) }
            return SidebarWaits.summary(try await SidebarWaits.rows(app, of: a) { $0.count == 2 })
        }
        let expected = "tabs=[A,B] active=B"
        run.check(
            "sidebar.close",
            passed: button == expected && commandW == expected,
            "button=\(button == expected ? "closed" : button) cmd-w=\(commandW == expected ? "closed" : commandW)"
        )

        // Leave A shown, so the run's final screenshot shows the window's first tab with the sidebar beside it.
        try await run.step("show A", timeout: E2ETimeouts.step) {
            try app.clickSidebarRow(of: a)
            try await SidebarWaits.untilShown(a)
        }
    }
}

/// Opens a tab whose title is far wider than the sidebar and checks its active row cuts the title short before the
/// close button rather than drawing under it, with the row's accessory slot empty.
struct SidebarLongTitleTest: E2ETest {
    let name = "sidebar.long-title"

    private static let title =
        "A page title long enough to run well past the width of the sidebar row, so the row has to cut it short"

    func run(_ run: E2ERun) async throws {
        let app = try SidebarWaits.app(run)
        let query = Self.title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("sidebar/page.html?name=\(query)"))
        }
        try await run.step("load", timeout: E2ETimeouts.firstLoad) {
            _ = try await page.waitForLoad(after: 0)
        }
        let row = try await run.step("row shows the title", timeout: E2ETimeouts.step) {
            try await SidebarWaits.rows(app, of: page) { $0.first?.title == Self.title && $0.first?.isActive == true }
                .first
        }
        let clears = row?.titleClearsClose == true
        run.check(
            name, passed: clears, clears ? "title ends before the close button" : "title runs under the close button")
    }
}

/// Chooses menu items by shortcut with their modifiers: closes tab B with Command-W, finds the Option-Command,
/// Shift-Command, uppercase, symbol and arrow key items by their shortcut and none for a combination no item has,
/// checks where every shortcut would go (each to the test window, the app's quit, hide and minimize refused) and
/// that choosing Quit or Minimize is refused, then closes the window with Shift-Command-W. Every shortcut goes
/// through the app's main menu, never DevTools.
struct SidebarMenuShortcutsTest: E2ETest {
    let name = "sidebar.menu"
    let checks = ["sidebar.menu-command", "sidebar.menu-modifiers", "sidebar.menu-routes"]

    func run(_ run: E2ERun) async throws {
        let sidebar = try SidebarWaits.app(run)
        guard let app = run.app as? any E2EMenuApp else { throw E2EError("the app has no menu to drive") }
        let a = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("sidebar/page.html?name=A"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let command = try await run.step("close B with Command-W", timeout: E2ETimeouts.firstLoad) {
            let b = try sidebar.clickNewTab(besides: a, opening: E2EFixture.url("sidebar/page.html?name=B"))
            _ = try await b.waitForLoad(after: 0)
            try await SidebarWaits.rows(sidebar, of: a) { $0.map(\.title) == ["A", "B"] }
            try app.chooseMenuItem(key: "w", modifiers: .command, in: b)
            while !b.isClosed { try await Task.sleep(nanoseconds: 10_000_000) }
            return SidebarWaits.summary(try await SidebarWaits.rows(sidebar, of: a) { $0.count == 1 })
        }
        run.check("sidebar.menu-command", passed: command == "tabs=[A] active=A", command)

        // What each lookup should find; nil where no item has the shortcut (an exact match, not a subset). Only
        // letters fold Shift: "{" is not "[" with Shift.
        let lookups: [(key: String, modifiers: E2EKeyModifiers, title: String?)] = [
            ("l", [.option, .command], "Downloads"),
            ("w", [.shift, .command], "Close Window"),
            ("W", .command, "Close Window"),
            ("w", .command, "Close Tab"),
            ("w", [.control, .option, .shift, .command], nil),
            ("[", .command, "Back"),
            ("[", [.shift, .command], nil),
            ("{", .command, nil),
            (E2EMenuKey.upArrow, .command, nil),
            (E2EMenuKey.function(5), [], nil),
            // AppKit's Emoji & Symbols item is Fn-E, which E2EKeyModifiers cannot name: never the bare key.
            ("e", [], nil),
        ]
        var problems: [String] = []
        for lookup in lookups {
            let title = app.menuItemTitle(key: lookup.key, modifiers: lookup.modifiers)
            if title != lookup.title {
                problems.append("\(lookup.modifiers.shortcut(lookup.key))=\(title ?? "none")")
            }
        }
        // Keys without a printable character show by name.
        let names = [
            E2EKeyModifiers.command.shortcut(E2EMenuKey.upArrow), E2EKeyModifiers().shortcut(E2EMenuKey.function(5)),
        ]
        if names != ["Cmd+Up", "F5"] { problems.append("names=\(names)") }

        let routes = try await run.step("menu routes", timeout: E2ETimeouts.step) {
            try Self.routeProblems(app: app, in: a)
        }
        run.check(
            "sidebar.menu-routes", passed: routes.problems.isEmpty,
            routes.problems.isEmpty
                ? routes.routes.map(\.description).joined(separator: " ") : routes.problems.joined(separator: " "))

        try await run.step("close the window with Shift-Command-W", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "w", modifiers: [.shift, .command], in: a)
            while !a.isClosed { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let detail = problems.isEmpty ? "lookups=\(lookups.count) shift-cmd-w=closed" : problems.joined(separator: " ")
        run.check("sidebar.menu-modifiers", passed: problems.isEmpty, detail)
    }

    /// Where every shortcut goes in `page`'s window, and what is wrong with it: Quit, Hide and Minimize must be
    /// refused, Close Tab must reach the window's controller (not the app delegate's fallback), and choosing Quit or Minimize must throw a refusal and leave the window open.
    @MainActor
    private static func routeProblems(app: any E2EMenuApp, in page: any E2EPage) throws
        -> (routes: [E2EMenuRoute], problems: [String])
    {
        let routes = try app.menuRoutes(in: page)
        var problems: [String] = []
        let expected = [
            ("Cmd+q", "refused"), ("Cmd+h", "refused"), ("Cmd+m", "refused"), ("Cmd+w", "BrowserWindowController"),
        ]
        for (shortcut, handler) in expected
        where !routes.contains(where: { $0.shortcut == shortcut && $0.handler == handler }) {
            problems.append("\(shortcut) not \(handler): \(routes.filter { $0.shortcut == shortcut })")
        }
        for key in ["q", "m"] {
            do {
                try app.chooseMenuItem(key: key, modifiers: .command, in: page)
                problems.append("Cmd+\(key) was chosen")
            } catch let error as E2EError where error.reason == .testEnded {
                throw error
            } catch let error as CancellationError {
                throw error
            } catch {
                if !"\(error)".contains("refused") { problems.append("Cmd+\(key): \(error)") }
            }
        }
        if page.isClosed { problems.append("the window closed") }
        return (routes, problems)
    }
}

/// Seeds two Spaces before the window opens: Work, on the test's profile, with a pinned folder holding a tab and a
/// nested folder, a pinned tab and two today tabs, and Home on a new profile named after the test with one today
/// tab. Checks the window shows Work nested as seeded, that every created Space, folder and tab resolves in the
/// window's sidebar store with its title, parent, Space and profile, and that a seed naming one new profile both
/// persistent and in memory is refused.
struct SidebarSeedTest: E2ETest {
    let name = "sidebar.seed"
    let checks = ["sidebar.seed", "sidebar.seed-ids", "sidebar.seed-refused"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EZonesApp & E2EStoreSeedApp else {
            throw E2EError("the app cannot seed a sidebar")
        }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
        let homeProfile = try app.testProfileID() + "-home"
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace(
                    "Work",
                    pinned: [
                        .folder("Docs", [.tab("P1", url: url("P1")), .folder("Inner", [.tab("P2", url: url("P2"))])]),
                        .tab("P3", url: url("P3")),
                    ],
                    today: [.tab("T1", url: url("T1")), .tab("T2", url: url("T2"))]
                ),
                E2ESeedSpace(
                    "Home", profile: .new(E2EProfile(id: homeProfile, isPersistent: false)),
                    today: [.tab("H1", url: url("H1"))]),
            ],
            activeSpace: "Work"
        )
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        // Each row's depth: sections at 0, items in a section at 1, and one deeper per folder.
        let expected = [
            ("favorites", 0), ("pinned", 0), ("Docs", 1), ("P1", 2), ("Inner", 2), ("P2", 3), ("P3", 1),
            ("divider", 0), ("today", 0), ("T1", 1), ("T2", 1),
        ].map { E2EOutlineRow(title: $0.0, level: $0.1) }
        // The outline once it reads as seeded, or what it read last shortly before the step's limit.
        let outline = try await run.step("outline", timeout: E2ETimeouts.step) {
            let deadline = Date().addingTimeInterval(E2EWaits.budget())
            while true {
                let outline = try app.sidebarOutlineRows(of: window.page)
                if outline == expected || Date() >= deadline { return outline }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        run.check("sidebar.seed", passed: outline == expected, outline.map(\.description).joined(separator: " | "))

        let problems = try await run.step("resolve the IDs", timeout: E2ETimeouts.step) {
            try Self.idProblems(of: window, homeProfile: homeProfile, app: app)
        }
        let ids = Array(window.spaceIDs.values) + Array(window.itemIDs.values)
        run.check(
            "sidebar.seed-ids", passed: problems.isEmpty,
            problems.isEmpty
                ? "resolved=\(ids.count) distinct=\(Set(ids).count) home=\(homeProfile)"
                : problems.joined(separator: " "))

        let refusal = try await run.step("refuse a profile both persistent and in memory", timeout: E2ETimeouts.step) {
            let id = try app.testProfileID() + "-clash"
            let clash = E2ESeed(spaces: [
                E2ESeedSpace("A", profile: .new(E2EProfile(id: id, isPersistent: false))),
                E2ESeedSpace("B", profile: .new(E2EProfile(id: id, isPersistent: true))),
            ])
            do {
                _ = try await app.openWindow(seeded: clash)
                return "opened"
            } catch let error as E2EError where error.reason == .testEnded {
                throw error
            } catch let error as CancellationError {
                throw error
            } catch {
                return "\(error)"
            }
        }
        run.check("sidebar.seed-refused", passed: refusal.contains("both persistent and in memory"), refusal)
    }

    /// Everything wrong with the seeded window's IDs as its sidebar store holds them: each Space, folder and tab
    /// must resolve with its kind, title, parent, Space and profile.
    @MainActor
    private static func idProblems(
        of window: E2ESeededWindow, homeProfile: String, app: any E2EStoreSeedApp
    ) throws -> [String] {
        var problems: [String] = []
        let ids = Array(window.spaceIDs.values) + Array(window.itemIDs.values)
        if Set(ids).count != ids.count { problems.append("ids repeat") }
        if Set(window.spaceIDs.keys) != ["Work", "Home"] { problems.append("spaces=\(window.spaceIDs.keys.sorted())") }
        let profiles = ["Work": try app.testProfileID(), "Home": homeProfile]
        for (name, profile) in profiles.sorted(by: { $0.key < $1.key }) {
            guard let id = window.spaceIDs[name], let entry = try app.storeEntry(id: id, in: window.page) else {
                problems.append("\(name)=unresolved")
                continue
            }
            if entry.kind != .space || entry.title != name || entry.profileID != profile {
                problems.append("\(name)=\(entry)")
            }
        }
        // Each item: its kind, its parent (a folder's name, or the section it sits in) and its Space.
        let items: [(name: String, kind: E2EStoreEntry.Kind, parent: String, space: String)] = [
            ("Docs", .folder, "pinned", "Work"), ("P1", .tab, "Docs", "Work"), ("Inner", .folder, "Docs", "Work"),
            ("P2", .tab, "Inner", "Work"), ("P3", .tab, "pinned", "Work"), ("T1", .tab, "today", "Work"),
            ("T2", .tab, "today", "Work"), ("H1", .tab, "today", "Home"),
        ]
        if Set(window.itemIDs.keys) != Set(items.map(\.name)) {
            problems.append("items=\(window.itemIDs.keys.sorted())")
        }
        for item in items {
            guard let id = window.itemIDs[item.name], let entry = try app.storeEntry(id: id, in: window.page) else {
                problems.append("\(item.name)=unresolved")
                continue
            }
            let parent = window.itemIDs[item.parent] ?? item.parent
            if entry.kind != item.kind || entry.title != item.name || entry.parent != parent
                || entry.spaceID != window.spaceIDs[item.space] || entry.profileID != profiles[item.space]
            {
                problems.append("\(item.name)=\(entry)")
            }
        }
        return problems
    }
}
