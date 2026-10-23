import Foundation

/// Tests of the vertical sidebar: it lists the window's tabs with icon and title, highlights the active one, and
/// its rows, close buttons and New Tab button drive the tabs. Fixtures in E2E/Fixtures/sidebar/.
@MainActor
enum SidebarViewTests {
    static let all: [any E2ETest] = [SidebarTabsTest()]
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
