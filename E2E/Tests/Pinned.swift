import Foundation

/// Tests of pinned tabs in the app: the tab row's Pin Tab and Unpin Tab, the Back to Pinned URL button that shows
/// only once the page has left its saved address, Replace Pinned URL with Current as the only way the saved address
/// changes, and the next tab becoming active when the selected pinned tab is closed. Uses the sidebar fixtures in
/// E2E/Fixtures/sidebar/.
@MainActor
enum PinnedTests {
    static let all: [any E2ETest] = [PinnedResetTest()]
}

/// Pins A from its menu, navigates it to B, resets it with its button, navigates to B again and replaces the saved
/// address, unpins it, pins it again and closes it while selected.
struct PinnedResetTest: E2ETest {
    let name = "pinned"
    let tags = ["smoke"]
    let checks = [
        "pinned.menu", "pinned.reset", "pinned.replace", "pinned.unpin", "pinned.close-next",
    ]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EPinnedApp else { throw E2EError("the app has no pinned tabs to drive") }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
        /// The fixture name in a saved address ("A" for the page named A), or the address itself.
        func label(_ address: String) -> String {
            URLComponents(string: address)?.queryItems?.first { $0.name == "name" }?.value ?? address
        }
        func navigate(_ page: any E2EPage, to name: String) async throws {
            let before = page.finishedLoads
            try page.load(url(name))
            _ = try await page.waitForLoad(after: before)
        }
        func wait(_ what: String, _ condition: () throws -> Bool) async throws {
            guard try await TabEdgesTests.until(condition) else { throw E2EError("never saw \(what)") }
        }

        let a = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: url("A"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let b = try await run.step("new tab B", timeout: E2ETimeouts.firstLoad) {
            let b = try await app.clickNewTab(besides: a, opening: url("B"))
            _ = try await b.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B"] }
            return b
        }

        // Pin Tab from the menu of A's row, shown before and after.
        let pin = try await run.step("pin A from its menu", timeout: E2ETimeouts.step) {
            let before = try app.tabMenu(of: a)
            try app.chooseTabMenuItem("Pin Tab", of: a)
            try await wait("A pinned") { try app.sidebarZone(of: a) == "pinned" }
            return (before: before, after: try app.tabMenu(of: a), saved: try app.savedURL(of: a))
        }
        run.check(
            "pinned.menu",
            passed: pin.before == ["Close Tab", "-", "Pin Tab"] && pin.after == ["Close Tab", "-", "Unpin Tab"]
                && label(pin.saved) == "A",
            "before=\(pin.before) after=\(pin.after) saved=\(label(pin.saved))")

        // Navigate A to B: the button shows, the menu offers Replace, and the saved address stays A.
        let away = try await run.step("navigate A to B", timeout: E2ETimeouts.step) {
            try app.clickSidebarRow(of: a)
            try await navigate(a, to: "B")
            try await wait("the Back to Pinned URL button") { try app.showsBackToPinned(a) }
            return (saved: try app.savedURL(of: a), menu: try app.tabMenu(of: a))
        }
        let navigated = label(try await a.string("location.href"))
        let reset = try await run.step("back to pinned URL", timeout: E2ETimeouts.step) {
            let before = a.finishedLoads
            try app.clickBackToPinned(a)
            _ = try await a.waitForLoad(after: before)
            try await wait("the button gone") { !(try app.showsBackToPinned(a)) }
            return (live: label(try await a.string("location.href")), saved: try app.savedURL(of: a))
        }
        run.check(
            "pinned.reset",
            passed: label(away.saved) == "A" && navigated == "B" && reset.live == "A" && label(reset.saved) == "A"
                && away.menu.contains("Replace Pinned URL with Current"),
            "saved=\(label(away.saved)) navigated=\(navigated) reset=\(reset.live)")

        // Navigating alone never changes the saved address; Replace does, and the button goes away on that page.
        let replaced = try await run.step("replace the pinned URL", timeout: E2ETimeouts.step) {
            try await navigate(a, to: "B")
            try await wait("the Back to Pinned URL button") { try app.showsBackToPinned(a) }
            let beforeReplace = try app.savedURL(of: a)
            try app.chooseTabMenuItem("Replace Pinned URL with Current", of: a)
            try await wait("the saved address replaced") { label(try app.savedURL(of: a)) == "B" }
            try await wait("the button gone") { !(try app.showsBackToPinned(a)) }
            return (before: beforeReplace, after: try app.savedURL(of: a), menu: try app.tabMenu(of: a))
        }
        run.check(
            "pinned.replace",
            passed: label(replaced.before) == "A" && label(replaced.after) == "B"
                && !replaced.menu.contains("Replace Pinned URL with Current"),
            "before=\(label(replaced.before)) after=\(label(replaced.after)) menu=\(replaced.menu)")

        // Unpin keeps the page the tab shows, in today.
        let unpinned = try await run.step("unpin A", timeout: E2ETimeouts.step) {
            try app.chooseTabMenuItem("Unpin Tab", of: a)
            try await wait("A in today") { try app.sidebarZone(of: a) == "today" }
            return (zone: try app.sidebarZone(of: a) ?? "none", saved: try app.savedURL(of: a))
        }
        run.check(
            "pinned.unpin", passed: unpinned.zone == "today" && label(unpinned.saved) == "B",
            "zone=\(unpinned.zone) saved=\(label(unpinned.saved))")

        // Closing the selected pinned tab unloads it, keeps its row and selects the next tab in sidebar order.
        let closed = try await run.step("close the selected pinned tab", timeout: E2ETimeouts.step) {
            try app.clickSidebarRow(of: a)
            try await navigate(a, to: "A")
            try app.chooseTabMenuItem("Pin Tab", of: a)
            try await wait("A pinned") { try app.sidebarZone(of: a) == "pinned" }
            try await wait("A selected") { try app.activeTabTitle(of: a) == "A" && a.isShown }
            // The row is made again after moving; its close button shows once it is the active row.
            try await wait("A's row active") { try app.sidebarRows(of: a).contains { $0.title == "A" && $0.isActive } }
            try app.clickSidebarClose(of: a)
            try await wait("the next tab active") { !a.isShown && b.isShown }
            return (active: try app.activeTabTitle(of: b) ?? "none", outline: try app.sidebarOutline(of: b))
        }
        run.check(
            "pinned.close-next",
            passed: closed.active == "B"
                && closed.outline == ["favorites", "pinned", "A", "divider", "today", "B"],
            "active=\(closed.active) outline=\(closed.outline.joined(separator: " | "))")
    }
}
