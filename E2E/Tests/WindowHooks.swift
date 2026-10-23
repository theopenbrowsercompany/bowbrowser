import Foundation

/// Tests of the window's engine hooks: a popup a page opens becomes a sidebar tab of its window, adopted right after
/// its opener with `window.opener` kept, and a page's context menu reaches the window, which runs the chosen item.
/// Fixtures in E2E/Fixtures/window/.
@MainActor
enum WindowHooksTests {
    static let all: [any E2ETest] = [
        WindowAdoptTest(),
        WindowContextMenuTest(),
        WindowInspectTest(),
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

/// Right clicking a link in tab A asks the window for a context menu that carries the link's address; the window
/// shows Bow's own menu, and choosing Open Link in New Tab opens the link as the today tab after A, in the
/// background, as a Cmd-click does.
struct WindowContextMenuTest: E2ETest {
    let name = "window.context-menu"

    func run(_ run: E2ERun) async throws {
        guard let hooks = run.app as? any E2EWindowHooksApp, let menus = run.app as? any E2EContextMenuApp else {
            throw E2EError("the app has no window hooks or context menus")
        }
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("window/menu.html"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let link = E2EFixture.url("window/opened.html")
        let menu = try await run.step("open the link in a new tab from its menu", timeout: E2ETimeouts.firstLoad) {
            try menus.chooseContextMenuItem("Open Link in New Tab")
            try await page.rightClick("#link")
            guard try await TabEdgesTests.until({ try !menus.contextMenus().isEmpty }) else {
                throw E2EError("no context menu reached the app")
            }
            let menu = try menus.contextMenus()[0]
            guard try await TabEdgesTests.until({ try hooks.rowTitles(besides: page) == ["A", "B"] }) else {
                throw E2EError("the link did not open as a tab: tabs=\(try hooks.rowTitles(besides: page))")
            }
            return menu
        }
        let rows = try hooks.rowTitles(besides: page)
        let shown = page.isShown
        run.check(
            name,
            passed: menu.linkURL == link && menu.chosen == "Open Link in New Tab" && rows == ["A", "B"] && shown,
            "link=\(menu.linkURL?.lastPathComponent ?? "none") tabs=[\(rows.joined(separator: ","))]"
                + (shown ? "" : " opener-shown=false") + " items=\(menu.items.filter { !$0.isEmpty })")
    }
}

/// Choosing Inspect from a page's context menu asks the tab's DevTools to inspect the element under the pointer.
/// An e2e run records the request instead of opening DevTools (the engine version Bow uses opens it only as a window
/// of its own, which would show on screen and activate the app), so the check sees the request and that nothing
/// showed.
struct WindowInspectTest: E2ETest {
    let name = "window.inspect"

    func run(_ run: E2ERun) async throws {
        guard let menus = run.app as? any E2EContextMenuApp else { throw E2EError("the app has no context menus") }
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("window/menu.html"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let screenBefore = menus.screenState
        let request = try await run.step("inspect from the menu", timeout: E2ETimeouts.firstLoad) {
            try menus.chooseContextMenuItem("Inspect")
            try await page.rightClick("#target")
            guard try await TabEdgesTests.until({ try menus.devToolsRequests(of: page).count > 0 }) else {
                throw E2EError("DevTools was not asked for: menus=\(try menus.contextMenus().count)")
            }
            return try menus.devToolsRequests(of: page)
        }
        let rect =
            try await page.evaluate(
                "(() => { const r = document.querySelector('#target').getBoundingClientRect();"
                    + " return [r.left, r.top, r.right, r.bottom]; })()") as? [Double] ?? []
        let inside =
            rect.count == 4
            && request.point.map {
                $0.x >= rect[0] && $0.y >= rect[1] && $0.x <= rect[2] && $0.y <= rect[3]
            } == true
        let screenAfter = menus.screenState
        let unchanged = screenAfter == screenBefore
        run.check(
            name, passed: request.count == 1 && inside && unchanged,
            "requests=\(request.count) at-element=\(inside)"
                + (unchanged ? "" : " screen=\(screenBefore)->\(screenAfter)"))
    }
}
