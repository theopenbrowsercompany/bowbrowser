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
    ]

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
