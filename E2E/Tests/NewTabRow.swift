import Foundation

/// Tests of the sidebar's New Tab row, which ends a Space's tab list and opens the command bar. Uses the sidebar
/// fixtures in E2E/Fixtures/sidebar/.
@MainActor
enum NewTabRowTests {
    static let all: [any E2ETest] = [NewTabRowTest(), NewTabRowPlacesTest()]

    typealias App = any E2ENewTabRowApp & E2ECommandBarApp & E2EStoreSeedApp

    static func app(_ run: E2ERun) throws -> App {
        guard let app = run.app as? App else { throw E2EError("the app has no New Tab row to drive") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("sidebar/page.html?name=\(name)") }
}

/// The row after today's tabs in a window with tab A: how it looks (the styling guide's tokens, a Pin tint on hover),
/// that clicking it opens the command bar with no tab opened (the same bar as Cmd+T), Escape closes it with nothing
/// opened, choosing an address opens the tab after the active one, and the row is no tab: it is never selected, a
/// drop on it is refused and a drop past it goes to the end of today.
struct NewTabRowTest: E2ETest {
    let name = "newtab"
    let tags = ["smoke"]
    let checks = [
        "newtab", "newtab.look", "newtab.bar", "newtab.dismiss", "newtab.open", "newtab.not-a-tab",
    ]

    func run(_ run: E2ERun) async throws {
        let app = try NewTabRowTests.app(run)
        let url = NewTabRowTests.url
        let a = try await run.step("open A", timeout: E2ETimeouts.firstLoad) {
            let a = try await app.openWindow(at: url("A"))
            _ = try await a.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A"] }
            return a
        }
        let start = try await run.step("read the row", timeout: E2ETimeouts.step) {
            (try app.newTabRow(of: a), try app.sidebarOutline(of: a), try app.tabSummary(of: a))
        }
        run.check(
            name,
            passed: start.0.isLast && start.0.index == start.1.count
                && start.1 == ["favorites", "pinned", "divider", "today", "A"]
                && start.2.hasSuffix("today=[A] active=A"),
            "row=\(start.0) outline=\(start.1) \(start.2)")

        let hovered = try await run.step("hover the row", timeout: E2ETimeouts.step) {
            try app.hoverNewTabRow(true, in: a)
            let on = try app.newTabRow(of: a)
            try app.hoverNewTabRow(false, in: a)
            return (on, try app.newTabRow(of: a))
        }
        run.check(
            "newtab.look",
            passed: start.0.title == "New tab" && start.0.height == 34 && start.0.usesUIFont && start.0.usesSoft
                && start.0.hasPlus && !start.0.showsHoverTint && hovered.0.showsHoverTint
                && !hovered.1.showsHoverTint,
            "rest=\(start.0) hovered=\(hovered.0) after=\(hovered.1)")

        let opened = try await run.step("click the row", timeout: E2ETimeouts.step) {
            try app.clickNewTabRow(in: a)
            let bar = try app.commandBar(of: a)
            let rows = try await bar.waitForResults()
            return (
                shown: bar.isShown, keyboard: bar.hasKeyboard, text: bar.text, rows: rows,
                summary: try app.tabSummary(of: a), selected: try app.newTabRow(of: a).isSelected
            )
        }
        run.check(
            "newtab.bar",
            passed: opened.shown && opened.keyboard && opened.text.isEmpty && opened.summary == start.2
                && !opened.selected && opened.rows.allSatisfy { $0.kind == "tab" },
            "shown=\(opened.shown) keyboard=\(opened.keyboard) text=\"\(opened.text)\" \(opened.summary) "
                + "selected=\(opened.selected) rows=\(opened.rows.map(\.description))")

        let dismissed = try await run.step("Escape", timeout: E2ETimeouts.step) {
            let bar = try app.commandBar(of: a)
            try bar.press(.escape)
            return (bar.isShown, try app.tabSummary(of: a), try app.sidebarRows(of: a).map(\.title))
        }
        run.check(
            "newtab.dismiss", passed: !dismissed.0 && dismissed.1 == start.2 && dismissed.2 == ["A"],
            "shown=\(dismissed.0) \(dismissed.1) rows=\(dismissed.2)")

        let b = try await run.step("choose an address", timeout: E2ETimeouts.firstLoad) {
            let b = try await app.clickNewTab(besides: a, opening: url("B"))
            _ = try await b.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B"] }
            return b
        }
        let after = try app.tabSummary(of: b)
        let barShown = try app.commandBar(of: b).isShown
        run.check(
            "newtab.open", passed: after.hasSuffix("today=[A,B] active=B") && !barShown, "\(after) bar=\(barShown)")

        let drops = try await run.step("drop on and past the row", timeout: E2ETimeouts.step) {
            let row = try app.newTabRow(of: a)
            var onRow = "moved"
            do {
                try app.dragTab(a, onRow: row.index, childIndex: -1)
            } catch let error as E2EError where error.reason != .testEnded {
                onRow = "refused"
            }
            let kept = try app.tabSummary(of: a)
            // Past the last row: the outline's gap below every section, here after the five sections.
            try app.dragTab(a, onRow: nil, childIndex: 5)
            let past = try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["B", "A"] }
            return (onRow, kept, SidebarWaits.summary(past), try app.newTabRow(of: a))
        }
        run.check(
            "newtab.not-a-tab",
            passed: drops.0 == "refused" && drops.1.hasSuffix("today=[A,B] active=B")
                && drops.2 == "tabs=[B,A] active=B" && !drops.3.isSelected && drops.3.isLast,
            "onRow=\(drops.0) \(drops.1) past=\(drops.2) row=\(drops.3)")
    }
}

/// The row ends the list whatever the Space holds: a Space with only pinned tabs (today empty) and an empty Space.
struct NewTabRowPlacesTest: E2ETest {
    let name = "newtab.places"
    let checks = ["newtab.places"]

    func run(_ run: E2ERun) async throws {
        let app = try NewTabRowTests.app(run)
        let url = NewTabRowTests.url
        let pinnedOnly = try await run.step("open a Space with only a pinned tab", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(
                seeded: E2ESeed(spaces: [E2ESeedSpace("Pins", pinned: [.tab("P1", url: url("P1"))])]))
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let first = try await run.step("read the row", timeout: E2ETimeouts.step) {
            (try app.newTabRow(of: pinnedOnly), try app.sidebarOutline(of: pinnedOnly))
        }
        let empty = try await run.step("open an empty Space", timeout: E2ETimeouts.firstLoad) {
            try await app.openWindow(seeded: E2ESeed(spaces: [E2ESeedSpace("Empty")])).page
        }
        // A window on a Space with no tab opens the home page in one; closing it leaves the Space empty.
        let second = try await run.step("close its tab and read the row", timeout: E2ETimeouts.step) {
            _ = try await app.closeTab(empty)
            let deadline = Date().addingTimeInterval(E2EWaits.budget())
            while true {
                let outline = try app.sidebarOutline(of: empty)
                if outline.last == "today" || Date() >= deadline {
                    return (try app.newTabRow(of: empty), outline)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        run.check(
            name,
            passed: first.0.isLast && first.1 == ["favorites", "pinned", "P1", "divider", "today"]
                && first.0.index == first.1.count && second.0.isLast
                && second.1 == ["favorites", "pinned", "divider", "today"] && second.0.index == second.1.count,
            "pinned-only row=\(first.0) outline=\(first.1) empty row=\(second.0) outline=\(second.1)")
    }
}
