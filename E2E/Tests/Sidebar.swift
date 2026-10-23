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
/// Shift-Command and uppercase key items by their shortcut and none for a combination no item has, then closes the
/// window with Shift-Command-W. Every shortcut goes through the app's main menu, never DevTools.
struct SidebarMenuShortcutsTest: E2ETest {
    let name = "sidebar.menu"
    let checks = ["sidebar.menu-command", "sidebar.menu-modifiers"]

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

        // What each lookup should find; nil where no item has the shortcut (an exact match, not a subset).
        let lookups: [(key: String, modifiers: E2EKeyModifiers, title: String?)] = [
            ("l", [.option, .command], "Downloads"),
            ("w", [.shift, .command], "Close Window"),
            ("W", .command, "Close Window"),
            ("w", .command, "Close Tab"),
            ("w", [.control, .option, .shift, .command], nil),
        ]
        var problems: [String] = []
        for lookup in lookups {
            let title = app.menuItemTitle(key: lookup.key, modifiers: lookup.modifiers)
            if title != lookup.title {
                problems.append("\(lookup.modifiers.shortcut(lookup.key))=\(title ?? "none")")
            }
        }
        try await run.step("close the window with Shift-Command-W", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "w", modifiers: [.shift, .command], in: a)
            while !a.isClosed { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let detail = problems.isEmpty ? "lookups=\(lookups.count) shift-cmd-w=closed" : problems.joined(separator: " ")
        run.check("sidebar.menu-modifiers", passed: problems.isEmpty, detail)
    }
}

/// Seeds two Spaces before the window opens: Work, on the test's profile, with a pinned folder holding a tab and a
/// nested folder, a pinned tab and two today tabs, and Home on a profile of its own with one today tab. Checks the
/// window shows Work laid out as seeded, and that every created Space, folder and tab came back with its own ID.
struct SidebarSeedTest: E2ETest {
    let name = "sidebar.seed"
    let checks = ["sidebar.seed", "sidebar.seed-ids"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EZonesApp & E2EStoreSeedApp else {
            throw E2EError("the app cannot seed a sidebar")
        }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
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
                    "Home", profile: .new(E2EProfile(id: "e2e-seed-home", isPersistent: false)),
                    today: [.tab("H1", url: url("H1"))]),
            ],
            activeSpace: "Work"
        )
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let expected = ["favorites", "pinned", "Docs", "P1", "Inner", "P2", "P3", "divider", "today", "T1", "T2"]
        let outline = try await run.step("outline", timeout: E2ETimeouts.step) {
            while true {
                let outline = try app.sidebarOutline(of: window.page)
                if outline == expected { return outline }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        run.check("sidebar.seed", passed: outline == expected, outline.joined(separator: " | "))

        let items = ["Docs", "P1", "Inner", "P2", "P3", "T1", "T2", "H1"]
        let ids = Array(window.spaceIDs.values) + Array(window.itemIDs.values)
        let complete =
            Set(window.spaceIDs.keys) == ["Work", "Home"] && Set(window.itemIDs.keys) == Set(items)
            && Set(ids).count == ids.count && !ids.contains("")
        run.check(
            "sidebar.seed-ids", passed: complete,
            "spaces=\(window.spaceIDs.keys.sorted()) items=\(window.itemIDs.keys.sorted()) distinct=\(Set(ids).count)")
    }
}
