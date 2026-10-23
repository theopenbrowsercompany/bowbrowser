import Foundation

/// Tests of the window's engine hooks: a popup a page opens becomes a sidebar tab of its window, adopted right after
/// its opener with `window.opener` kept. Fixtures in
/// E2E/Fixtures/window/.
@MainActor
enum WindowHooksTests {
    static let all: [any E2ETest] = [
        WindowAdoptTest()
    ]
}

/// A target="_blank" link clicked in tab A opens B, which the window adopts as the sidebar tab after A, shown and
/// still connected to A (the link asks for `rel="opener"`, since target="_blank" alone implies noopener). The click
/// had no modifiers, and the request says so.
struct WindowAdoptTest: E2ETest {
    let name = "window.adopt"

    func run(_ run: E2ERun) async throws {
        guard let hooks = run.app as? any E2EWindowHooksApp else { throw E2EError("the app has no window hooks") }
        let opener = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("window/opener.html"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let adopted = try await run.step("click a target blank link", timeout: E2ETimeouts.firstLoad) {
            try hooks.adoptPopups(of: opener)
            try await opener.click("#open")
            guard try await TabEdgesTests.until({ try !hooks.adoptedPages(of: opener).isEmpty }) else {
                throw E2EError("no popup was adopted (requests=\(try hooks.popupModifiers(of: opener).count))")
            }
            let page = try hooks.adoptedPages(of: opener)[0]
            _ = try await page.waitForLoad(after: 0)
            let keptOpener = try await page.evaluate("window.opener !== null") as? Bool ?? false
            return (page: page, keptOpener: keptOpener)
        }
        let rows = try hooks.rowTitles(besides: opener)
        let shown = adopted.page.contentView != nil
        let modifiers = try hooks.popupModifiers(of: opener)
        let plain = modifiers == [E2EClickModifiers(command: false, shift: false)]
        run.check(
            name, passed: rows == ["A", "B"] && adopted.keptOpener && shown && plain,
            "tabs=[\(rows.joined(separator: ","))] opener=\(adopted.keptOpener ? "kept" : "lost")"
                + (shown ? "" : " shown=false") + (plain ? "" : " modifiers=\(modifiers)"))
    }
}
