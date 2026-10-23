import Foundation

/// Tests of Ctrl+Tab by recency. Fixtures in E2E/Fixtures/recent/.
@MainActor
enum RecentTabsTests {
    static let all: [any E2ETest] = [RecentTabsTest()]

    typealias App = any E2ERecentTabsApp & E2ECommandBarApp & E2EStoreSeedApp

    static func app(_ run: E2ERun) throws -> App {
        guard let app = run.app as? App else { throw E2EError("the app has no recent tabs hooks") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("recent/\(name).html") }

    /// The window's tab summary once it equals `expected`, or as it reads shortly before the step's limit.
    static func summary(of page: any E2EPage, app: App, is expected: String) async throws -> String {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while true {
            let summary = try app.tabSummary(of: page)
            if summary == expected || Date() >= deadline { return summary }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Tabs A, B and C in the work Space and D in the home Space, shown in the order A, B, C. Ctrl+Tab goes to the tab
/// before the last, Tab twice to the third most recent, Shift+Tab steps back, Escape cancels, a tab in another Space
/// is listed with its Space and brings it on screen, and the overlay and its Ctrl monitor go away with the release.
struct RecentTabsTest: E2ETest {
    let name = "mru"
    let tags = ["smoke"]
    let checks = ["mru", "mru.third", "mru.shift", "mru.space", "mru.escape", "mru.closes", "mru.engine-key"]

    func run(_ run: E2ERun) async throws {
        let app = try RecentTabsTests.app(run)
        let home = try app.testProfileID() + "-home"
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace(
                    "work",
                    today: [
                        .tab("A", url: RecentTabsTests.url("a")), .tab("B", url: RecentTabsTests.url("b")),
                        .tab("C", url: RecentTabsTests.url("c")),
                    ]),
                E2ESeedSpace(
                    "home", profile: .new(E2EProfile(id: home, isPersistent: false)),
                    today: [.tab("D", url: RecentTabsTests.url("d"))]),
            ],
            activeSpace: "work")
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let page = window.page
        func shown(_ summary: String) -> String { "space=work today=[A,B,C] active=\(summary)" }

        // Show B, then C: the recency order is C, B, A, then D, which was never shown.
        for tab in ["B", "C"] {
            let summary = try await run.step("show \(tab)", timeout: E2ETimeouts.firstLoad) {
                try app.clickTabRow(window.itemIDs[tab] ?? "", in: page)
                return try await RecentTabsTests.summary(of: page, app: app, is: shown(tab))
            }
            guard summary == shown(tab) else { throw E2EError("showing \(tab) gave \(summary)") }
        }

        // A tap: Ctrl+Tab highlights the tab used before this one; releasing Ctrl shows it.
        let tap = try await run.step("Ctrl+Tab and release", timeout: E2ETimeouts.step) {
            guard try app.pressRecentTabs(shift: false, in: page) else { throw E2EError("Ctrl+Tab was not claimed") }
            let open = try app.recentTabs(of: page)
            try app.releaseControl(in: page)
            let summary = try await RecentTabsTests.summary(of: page, app: app, is: shown("B"))
            return (open, summary, try app.recentTabs(of: page))
        }
        run.check(
            "mru",
            passed: tap.0.isShown && tap.0.highlighted == 1
                && tap.0.rows == ["C @ work", "B @ work", "A @ work", "D @ home"] && tap.1 == shown("B"),
            "open=\(tap.0) after=\(tap.1)")
        run.check("mru.closes", passed: !tap.2.isShown && !tap.2.monitoring, "after release: \(tap.2)")

        // The order is B, C, A, D: Tab twice reaches the third most recent, A.
        let third = try await run.step("Ctrl+Tab twice and release", timeout: E2ETimeouts.step) {
            _ = try app.pressRecentTabs(shift: false, in: page)
            _ = try app.pressRecentTabs(shift: false, in: page)
            let open = try app.recentTabs(of: page)
            try app.releaseControl(in: page)
            return (open, try await RecentTabsTests.summary(of: page, app: app, is: shown("A")))
        }
        run.check(
            "mru.third", passed: third.0.highlighted == 2 && third.1 == shown("A"),
            "highlighted=\(third.0.highlighted.map(String.init) ?? "none") after=\(third.1)")

        // The order is A, B, C, D: Ctrl+Tab then Shift+Ctrl+Tab is back on the shown tab, so nothing changes.
        let back = try await run.step("Ctrl+Tab, Shift+Tab and release", timeout: E2ETimeouts.step) {
            _ = try app.pressRecentTabs(shift: false, in: page)
            let forward = try app.recentTabs(of: page).highlighted
            _ = try app.pressRecentTabs(shift: true, in: page)
            let open = try app.recentTabs(of: page)
            try app.releaseControl(in: page)
            return (forward, open.highlighted, try app.tabSummary(of: page), try app.recentTabs(of: page))
        }
        run.check(
            "mru.shift", passed: back.0 == 1 && back.1 == 0 && back.2 == shown("A") && !back.3.isShown,
            "forward=\(back.0.map(String.init) ?? "none") back=\(back.1.map(String.init) ?? "none") after=\(back.2)")

        // Shift+Ctrl+Tab from the start wraps to the least recent tab, D, which lives in the home Space.
        let space = try await run.step("Shift+Ctrl+Tab to D and release", timeout: E2ETimeouts.firstLoad) {
            _ = try app.pressRecentTabs(shift: true, in: page)
            let open = try app.recentTabs(of: page)
            try app.releaseControl(in: page)
            let summary = try await RecentTabsTests.summary(
                of: page, app: app, is: "space=home today=[D] active=D")
            return (open, summary)
        }
        run.check(
            "mru.space",
            passed: space.0.highlighted == 3 && space.0.rows.last == "D @ home"
                && space.1 == "space=home today=[D] active=D",
            "open=\(space.0) after=\(space.1)")

        // The order is D, A, B, C: Escape closes the overlay and keeps D, and a later release changes nothing.
        let escape = try await run.step("Ctrl+Tab, Escape and release", timeout: E2ETimeouts.step) {
            _ = try app.pressRecentTabs(shift: false, in: page)
            let open = try app.recentTabs(of: page)
            let claimed = try app.pressEscapeBeforePage(in: page)
            let closed = try app.recentTabs(of: page)
            try app.releaseControl(in: page)
            return (open, claimed, closed, try app.tabSummary(of: page))
        }
        run.check(
            "mru.escape",
            passed: escape.0.isShown && escape.1 && !escape.2.isShown && !escape.2.monitoring
                && escape.3 == "space=home today=[D] active=D",
            "open=\(escape.0) claimed=\(escape.1) closed=\(escape.2) after=\(escape.3)")

        // The engine's own key path: a Ctrl+Tab sent to the page reaches the switcher before the page does.
        let engine = try await run.step("Ctrl+Tab through the page", timeout: E2ETimeouts.step) {
            let current = window.page
            try await current.press(letter: "\t", macKeyCode: 48, modifiers: .control)
            var state = try app.recentTabs(of: page)
            let deadline = Date().addingTimeInterval(E2EWaits.budget())
            while !state.isShown, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
                state = try app.recentTabs(of: page)
            }
            _ = try app.pressEscapeBeforePage(in: page)
            return state
        }
        run.check("mru.engine-key", passed: engine.isShown && engine.highlighted == 1, "after the page key: \(engine)")
    }
}
