import Foundation

/// Tests of where the pages a page opens go: a new tab link, a modified link click and a script's `window.open`
/// become sidebar tabs of the window, right after the tab that opened them, shown at once for a plain link and in
/// the background for a Cmd-click or middle click; a page that opens one without a click opens nothing. Fixtures in
/// E2E/Fixtures/popups/: opener.html (titled A)
/// opens opened.html (titled B), which reports its load back to A.
@MainActor
enum PopupsTests {
    static let all: [any E2ETest] = [
        PopupsNewTabTest(),
        PopupsLinkClickTest(name: "popups.cmd_click", modifiers: .command, shown: "A"),
        PopupsLinkClickTest(name: "popups.cmd_shift_click", modifiers: [.command, .shift], shown: "B"),
        PopupsLinkClickTest(name: "popups.middle_click", button: .middle, shown: "A"),
        PopupsBlockedTest(),
        PopupsOpenerTest(),
        PopupsStormTest(),
        PopupsOAuthTest(),
        PopupsPanelCloseTest(),
        PopupsPanelWindowCloseTest(),
    ]

    /// Clicks the sign in button, which opens login.html in a sized popup, and waits until it says it is ready
    /// through `window.opener` (message number `count`).
    static func openLogin(_ page: any E2EPage, count: Int = 1) async throws {
        try await page.click("#login")
        try await E2EWaits.until(page, "window.bowMessages.filter(m => m === 'login-ready').length >= \(count)")
    }

    /// The panels as "480x560".
    static func sizes(_ panels: [E2EPopupPanel]) -> String {
        panels.map { "\(Int($0.contentSize.width))x\(Int($0.contentSize.height))" }.joined(separator: ",")
    }

    /// Opens a window on opener.html (A) and waits for it to load.
    static func openOpener(_ run: E2ERun) async throws -> (app: any E2EPopupsApp, page: any E2EPage) {
        guard let app = run.app as? any E2EPopupsApp else { throw E2EError("the app has no popup handling") }
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("popups/opener.html"))
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the opener loaded with status \(status)") }
            return page
        }
        return (app, page)
    }

    /// Waits until `count` pages A opened have loaded, as they report on their broadcast channel.
    static func untilLoaded(_ page: any E2EPage, count: Int = 1) async throws {
        try await E2EWaits.until(page, "window.bowLoaded.length >= \(count)")
    }

    /// The window's tabs as "[A,B]".
    static func list(_ titles: [String]) -> String { "[\(titles.joined(separator: ","))]" }
}

/// A plain click on a `target="_blank"` link opens B as a tab right after A, shown at once.
struct PopupsNewTabTest: E2ETest {
    let name = "popups.newtab"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        try await run.step("click a target blank link", timeout: E2ETimeouts.firstLoad) {
            try await page.click("#blank")
            try await PopupsTests.untilLoaded(page)
        }
        let tabs = try app.popupTabTitles(besides: page)
        let shown = try app.shownPopupTabTitle(besides: page)
        let passed = tabs == ["A", "B"] && shown == "B"
        run.check(
            name, passed: passed, "tabs=\(PopupsTests.list(tabs)) shown=\(shown ?? "none")")
    }
}

/// A modified click on a plain link (Cmd-click, Cmd-Shift-click or a middle click) opens B as a new tab right after
/// A, before the tab that already followed it (C), shown or in the background as `shown` says, and leaves A on its
/// page.
struct PopupsLinkClickTest: E2ETest {
    let name: String
    let button: E2EMouseButton
    let modifiers: E2EInputModifiers
    let shown: String

    init(name: String, button: E2EMouseButton = .left, modifiers: E2EInputModifiers = [], shown: String) {
        self.name = name
        self.button = button
        self.modifiers = modifiers
        self.shown = shown
    }

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        try await run.step("open tab C after A", timeout: E2ETimeouts.step) {
            _ = try run.app.openTab(at: E2EFixture.url("popups/other.html"), besides: page, select: false)
        }
        try await run.step("click the link", timeout: E2ETimeouts.firstLoad) {
            try await page.click("#link", button: button, modifiers: modifiers)
            try await PopupsTests.untilLoaded(page)
        }
        let tabs = try app.popupTabTitles(besides: page)
        let shownTitle = try app.shownPopupTabTitle(besides: page)
        let stayed = try await page.string("location.pathname").hasSuffix("/opener.html")
        let passed = tabs == ["A", "B", "C"] && shownTitle == shown && stayed
        run.check(
            name, passed: passed,
            "tabs=\(PopupsTests.list(tabs)) shown=\(shownTitle ?? "none")" + (stayed ? "" : " opener-navigated=true"))
    }
}

/// A `window.open` with no click opens nothing (the page gets null back), and the page still opens B as a tab from a
/// click afterwards.
struct PopupsBlockedTest: E2ETest {
    let name = "popups.blocked"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        let opened = try await run.step("open a page without a click", timeout: E2ETimeouts.step) {
            try await page.evaluate("window.open('opened.html?via=script') !== null") as? Bool ?? true
        }
        let blockedTabs = try app.popupTabTitles(besides: page)
        try await run.step("open a page from a click", timeout: E2ETimeouts.firstLoad) {
            try await page.click("#open")
            try await PopupsTests.untilLoaded(page)
        }
        let loaded = try await page.string("window.bowLoaded.join(',')")
        let tabs = try app.popupTabTitles(besides: page)
        let passed = !opened && blockedTabs == ["A"] && loaded == "loaded?via=open" && tabs == ["A", "B"]
        run.check(
            name, passed: passed,
            "opened=\(opened ? "window" : "null") tabs=\(PopupsTests.list(blockedTabs)) "
                + "after-click=\(PopupsTests.list(tabs))" + (passed ? "" : " loaded=\"\(loaded)\""))
    }
}

/// A `window.open` from a click opens B as a tab still connected to A: B's postMessage through `window.opener`
/// reaches A.
struct PopupsOpenerTest: E2ETest {
    let name = "popups.opener"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        try await run.step("open a page from a click", timeout: E2ETimeouts.firstLoad) {
            try await page.click("#open")
            try await E2EWaits.until(page, "window.bowMessages.includes('opener?via=open')")
        }
        let tabs = try app.popupTabTitles(besides: page)
        let shown = try app.shownPopupTabTitle(besides: page)
        let passed = tabs == ["A", "B"] && shown == "B"
        run.check(
            name, passed: passed,
            "tabs=\(PopupsTests.list(tabs)) postMessage=received" + (passed ? "" : " shown=\(shown ?? "none")"))
    }
}

/// One click that calls `window.open` twenty times opens one tab: the click allows one new page, and the rest come
/// without one.
struct PopupsStormTest: E2ETest {
    let name = "popups.storm"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        let opened = try await run.step("open twenty pages from one click", timeout: E2ETimeouts.firstLoad) {
            try await page.click("#storm")
            try await PopupsTests.untilLoaded(page)
            return try await page.evaluate("window.bowStorm") as? Int ?? -1
        }
        let tabs = try app.popupTabTitles(besides: page)
        let passed = opened == 1 && tabs == ["A", "B"]
        run.check(name, passed: passed, "opened=\(opened) tabs=\(PopupsTests.list(tabs))")
    }
}

/// A sign in flow: a click opens login.html with `window.open` and a size, which opens in a popup panel attached to
/// the window at the size asked for, not as a tab; the panel's page reports back through `window.opener`, and when
/// it calls `window.close()` the panel closes and the window still has only A.
struct PopupsOAuthTest: E2ETest {
    let name = "popups.oauth"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        try await run.step("open the sign in popup", timeout: E2ETimeouts.firstLoad) {
            try await PopupsTests.openLogin(page)
        }
        let panels = try app.popupPanels(besides: page)
        let tabsWhileOpen = try app.popupTabTitles(besides: page)
        let received = try await run.step("finish the sign in", timeout: E2ETimeouts.step) {
            _ = try await page.evaluate("window.bowLogin.postMessage('finish', '*'); true")
            try await E2EWaits.until(page, "window.bowMessages.includes('signed-in') && window.bowLogin.closed")
            try await app.untilNoPopupPanels(besides: page)
            return true
        }
        let tabs = try app.popupTabTitles(besides: page)
        let panel = panels.first
        let passed =
            panels.count == 1 && panel?.contentSize == CGSize(width: 480, height: 560) && panel?.attached == true
            && panel?.intrudes == false && tabsWhileOpen == ["A"] && received && tabs == ["A"]
        run.check(
            name, passed: passed,
            "panel=\(PopupsTests.sizes(panels)) attached=\(panel?.attached == true ? "yes" : "no") "
                + "postMessage=received closed=yes tabs=\(PopupsTests.list(tabs))"
                + (passed
                    ? ""
                    : " panels=\(panels.count) intrudes=\(panel?.intrudes ?? false) "
                        + "frame=\(panel.map { "\($0.frame)" } ?? "none") parent=\(panel.map { "\($0.parentFrame)" } ?? "none") "
                        + "tabs-while-open=\(PopupsTests.list(tabsWhileOpen))"))
    }
}

/// A sized popup without a click opens nothing; a panel the person closes with its close button goes, and its page
/// closes (the opener sees it closed); a second panel closes when the tab that opened it closes.
struct PopupsPanelCloseTest: E2ETest {
    let name = "popups.panel_close"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        let opened = try await run.step("open a sized popup without a click", timeout: E2ETimeouts.step) {
            try await page.evaluate("window.open('login.html', 'quiet', 'width=400,height=400') !== null") as? Bool
                ?? true
        }
        let blockedPanels = try app.popupPanels(besides: page).count
        try await run.step("open the sign in popup", timeout: E2ETimeouts.firstLoad) {
            try await PopupsTests.openLogin(page)
        }
        let panelsOpen = try app.popupPanels(besides: page).count
        try await run.step("close the panel", timeout: E2ETimeouts.step) {
            try app.closePopupPanel(besides: page)
            try await app.untilNoPopupPanels(besides: page)
            try await E2EWaits.until(page, "window.bowLogin.closed")
        }
        try await run.step("open the sign in popup again", timeout: E2ETimeouts.firstLoad) {
            try await PopupsTests.openLogin(page, count: 2)
        }
        let reopened = try app.popupPanels(besides: page).count
        let tabs = try app.popupTabTitles(besides: page)
        // Closing the tab that opened the panel closes the panel; tab C keeps the window open.
        try await run.step("close the opener tab", timeout: E2ETimeouts.step) {
            _ = try run.app.openTab(at: E2EFixture.url("popups/other.html"), besides: page, select: false)
            guard try await run.app.closeTab(page) else { throw E2EError("the opener tab stayed open") }
            try await app.untilNoPopupPanels(besides: page)
        }
        let passed = !opened && blockedPanels == 0 && panelsOpen == 1 && reopened == 1 && tabs == ["A"]
        run.check(
            name, passed: passed,
            "without-click=\(opened ? "opened" : "blocked") close-button=closed reopened=\(reopened) "
                + "tabs=\(PopupsTests.list(tabs)) opener-closed=closed"
                + (passed ? "" : " panels=\(panelsOpen) blocked-panels=\(blockedPanels)"))
    }
}

/// Closing the window while a popup panel is open closes the panel and its page with it; `e2e.isolation` then
/// checks that no browser was left open.
struct PopupsPanelWindowCloseTest: E2ETest {
    let name = "popups.panel_window_close"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PopupsTests.openOpener(run)
        try await run.step("open the sign in popup", timeout: E2ETimeouts.firstLoad) {
            try await PopupsTests.openLogin(page)
        }
        let panels = try app.popupPanels(besides: page).count
        try await run.step("close the window", timeout: E2ETimeouts.step) {
            try await run.app.closeWindow(of: page)
            try await app.untilNoPopupPanels(besides: page)
        }
        run.check(name, passed: panels == 1, "panels=\(panels) window-closed=panel-closed")
    }
}
