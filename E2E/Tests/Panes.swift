import Foundation

/// Tests of the window core's panes: the page area shows one to four tabs side by side, one focused, and returns to
/// a single view once only one is left. The split view feature builds on this. Fixtures in E2E/Fixtures/panes/.
@MainActor
enum PanesTests {
    static let all: [any E2ETest] = [
        PanesContractTest()
    ]
}

/// Tabs A to D in one window. Four panes show the four tabs side by side at equal widths with C focused; then two
/// panes show A and C with A focused and outlined. Focusing pane 1 makes C the selected and active tab with the
/// keyboard in its page; a click in pane 0 focuses A again. A view placed over the page area stays in front of the
/// panes as they change. Closing A, the focused pane's tab, leaves C alone (the other pane, not B, A's sidebar
/// neighbour), filling the page area, focused and active.
struct PanesContractTest: E2ETest {
    let name = "panes.contract"
    let checks = ["panes.four", "panes.two", "panes.focus", "panes.click", "panes.overlay", "panes.close"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EPanesApp else { throw E2EError("the app has no panes") }
        let pages = try await run.step("open tabs A to D", timeout: E2ETimeouts.firstLoad) {
            let first = try await run.app.openWindow(at: E2EFixture.url("panes/a.html"))
            var pages = [first]
            for name in ["b", "c", "d"] {
                pages.append(
                    try run.app.openTab(at: E2EFixture.url("panes/\(name).html"), besides: first, select: true))
            }
            for page in pages { _ = try await page.waitForLoad(after: 0) }
            return pages
        }
        let (a, c) = (pages[0], pages[2])

        let four = try await run.step("show four panes", timeout: E2ETimeouts.step) {
            let shown = try app.showPanes(pages, focused: pages[2])
            return (shown, try app.panes(besides: a))
        }
        run.check(
            "panes.four",
            passed: four.0 && four.1.titles == ["A", "B", "C", "D"] && four.1.focusedIndex == 2
                && four.1.selectedTitle == "C" && four.1.activeTitle == "C" && four.1.fillsEqually()
                && four.1.outlined == [2],
            "shown=\(four.0) \(four.1)")

        let overlay = try app.addPageOverlay(besides: a)
        let two = try await run.step("show two panes", timeout: E2ETimeouts.step) {
            let shown = try app.showPanes([a, c], focused: a)
            return (shown, try app.panes(besides: a))
        }
        run.check(
            "panes.two",
            passed: two.0 && two.1.titles == ["A", "C"] && two.1.focusedIndex == 0 && two.1.selectedTitle == "A"
                && two.1.activeTitle == "A" && two.1.fillsEqually() && two.1.outlined == [0],
            "shown=\(two.0) \(two.1)")

        let focus = try await run.step("focus pane 1", timeout: E2ETimeouts.step) {
            let focused = try app.focusPane(at: 1, besides: a)
            return (focused, try app.panes(besides: a))
        }
        run.check(
            "panes.focus",
            passed: focus.0 && focus.1.titles == ["A", "C"] && focus.1.focusedIndex == 1
                && focus.1.selectedTitle == "C" && focus.1.activeTitle == "C" && focus.1.outlined == [1]
                && focus.1.keyboardInFocused,
            "focused=\(focus.0) \(focus.1)")

        let click = try await run.step("click pane 0", timeout: E2ETimeouts.step) {
            try app.clickPane(at: 0, besides: a)
            guard try await TabEdgesTests.until({ try app.panes(besides: a).focusedIndex == 0 }) else {
                throw E2EError("the click did not focus pane 0: \(try app.panes(besides: a))")
            }
            return try app.panes(besides: a)
        }
        run.check(
            "panes.click",
            passed: click.titles == ["A", "C"] && click.selectedTitle == "A" && click.activeTitle == "A"
                && click.outlined == [0],
            "\(click)")

        let front = try app.panes(besides: a).frontmostTag
        run.check("panes.overlay", passed: front == overlay, "front=\(front) overlay=\(overlay)")

        let closed = try await run.step("close the focused pane's tab", timeout: E2ETimeouts.step) {
            guard try await run.app.closeTab(a) else { throw E2EError("tab A did not close") }
            guard try await TabEdgesTests.until({ try app.panes(besides: c).titles.count == 1 }) else {
                throw E2EError("the panes stayed: \(try app.panes(besides: c))")
            }
            return try app.panes(besides: c)
        }
        run.check(
            "panes.close",
            passed: closed.titles == ["C"] && closed.selectedTitle == "C" && closed.activeTitle == "C"
                && closed.fillsEqually() && closed.outlined.isEmpty && c.isShown,
            "\(closed)")
    }
}
