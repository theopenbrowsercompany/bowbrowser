import Foundation

/// Tests of Peek: a Shift-click, or a link from a pinned tab that leaves its site, previews the page in a card over
/// the window; Escape closes it, Open as Tab moves the same page into a tab, and closing or leaving its source tab
/// takes it away. Fixtures in E2E/Fixtures/peek/: source.html (titled A) links to target.html (titled B) on its own
/// site and on another (`https://other.bow.test/`), and other.html is C.
@MainActor
enum PeekTests {
    static let all: [any E2ETest] = [
        PeekOverlayTest(),
        PeekPromoteTest(),
        PeekPinnedTest(),
        PeekSourceCloseTest(),
        PeekSwitchTest(),
        PeekStayTest(),
        PeekRedirectTest(),
        PeekWindowCloseTest(),
    ]

    /// Opens a window on a pinned tab on source.html (A) and waits for it to load.
    static func openPinnedSource(_ run: E2ERun) async throws -> (app: any E2EPeekApp, page: any E2EPage) {
        guard let seeder = run.app as? any E2EStoreSeedApp, let app = run.app as? any E2EPeekApp else {
            throw E2EError("the app cannot seed a sidebar or has no Peek")
        }
        let page = try await run.step("open a window on a pinned tab", timeout: E2ETimeouts.firstLoad) {
            let seed = E2ESeed(spaces: [
                E2ESeedSpace("Home", pinned: [.tab("A", url: E2EFixture.url("peek/source.html"))])
            ])
            let page = try await seeder.openWindow(seeded: seed).page
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the pinned tab loaded with status \(status)") }
            return page
        }
        return (app, page)
    }

    /// Opens a window on source.html (A) and waits for it to load.
    static func openSource(_ run: E2ERun) async throws -> (app: any E2EPeekApp, page: any E2EPage) {
        guard let app = run.app as? any E2EPeekApp else { throw E2EError("the app has no Peek") }
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("peek/source.html"))
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the source loaded with status \(status)") }
            return page
        }
        return (app, page)
    }

    /// Opens C in a tab after A, in the background, and waits for it to load.
    static func openOther(_ run: E2ERun, besides page: any E2EPage) async throws -> any E2EPage {
        try await run.step("open tab C", timeout: E2ETimeouts.firstLoad) {
            let other = try run.app.openTab(at: E2EFixture.url("peek/other.html"), besides: page, select: false)
            _ = try await other.waitForLoad(after: 0)
            return other
        }
    }

    /// Clicks `selector` in `page` with `modifiers` and waits for the Peek's page to show B, loaded.
    static func openPeek(
        _ run: E2ERun, app: any E2EPeekApp, page: any E2EPage, selector: String = "#link",
        modifiers: E2EInputModifiers = .shift
    ) async throws -> any E2EPage {
        try await run.step("open a Peek", timeout: E2ETimeouts.firstLoad) {
            try await page.click(selector, modifiers: modifiers)
            let peek = try await app.untilPeek(besides: page)
            // Waits on the page's own reported state, since its first load may have ended before the test tracked it,
            // and a page script run while it still commits would lose its context.
            let loaded = try await E2EWaits.until {
                try app.peek(besides: page).map { $0.title == "B" && !$0.isLoading } ?? false
            }
            guard loaded else {
                throw E2EError("the Peek did not load B: \(String(describing: try app.peek(besides: page)))")
            }
            return peek
        }
    }

    /// The window's tabs as "[A,B]".
    static func list(_ titles: [String]) -> String { "[\(titles.joined(separator: ","))]" }
}

/// Shift-click on a link opens B in a Peek over A, dimmed and above the panes, A still the shown tab; Escape in the
/// Peek's page closes it, leaves A shown and closes B's browser.
struct PeekOverlayTest: E2ETest {
    let name = "peek"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PeekTests.openSource(run)
        let peekPage = try await PeekTests.openPeek(run, app: app, page: page)
        let state = try app.peek(besides: page)
        let overlay = try await peekPage.string("document.title")
        let under = try app.shownPopupTabTitle(besides: page) ?? "none"
        // The page paints in the card at the card's size (screenshots cannot show a Peek's web content).
        let rendering = try await run.step("check the Peek page paints", timeout: E2ETimeouts.step) {
            try await E2EWaits.untilRendering(peekPage)
            return try await peekPage.string("innerWidth + 'x' + innerHeight")
        }
        let cardSize = state.map { "\(Int($0.cardSize.width))x\(Int($0.cardSize.height))" } ?? "none"
        let afterEscape = try await run.step("press Escape", timeout: E2ETimeouts.step) {
            try await peekPage.press(.escape)
            guard try await app.untilNoPeek(besides: page) else { return "peek-open" }
            return try app.shownPopupTabTitle(besides: page) ?? "none"
        }
        let closed = try await E2EWaits.until { peekPage.isClosed }
        let looks = (state.map { $0.overPanes && $0.dimmed && $0.showsPage } ?? false) && rendering == cardSize
        let tabs = try app.popupTabTitles(besides: page)
        let passed = overlay == "B" && under == "A" && afterEscape == "A" && looks && closed && tabs == ["A"]
        var detail = "overlay=\(overlay) under=\(under) after_esc=\(afterEscape)"
        if !passed {
            detail +=
                " card=\(state.map { "\($0)" } ?? "none") page=\(rendering) page_closed=\(closed) tabs=\(PeekTests.list(tabs))"
        }
        run.check(name, passed: passed, detail)
    }
}

/// Open as Tab moves B into a tab right after A (before C), shown, with the same browser and no reload: the page keeps
/// its document and its load count.
struct PeekPromoteTest: E2ETest {
    let name = "peek.promote"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PeekTests.openSource(run)
        _ = try await PeekTests.openOther(run, besides: page)
        let peekPage = try await PeekTests.openPeek(run, app: app, page: page)
        let loadID = try await peekPage.string("window.bowLoadID")
        let loads = peekPage.finishedLoads
        try await run.step("press Open as Tab", timeout: E2ETimeouts.step) {
            try app.press(.openAsTab, besides: page)
            _ = try await app.untilNoPeek(besides: page)
        }
        let tabs = try app.popupTabTitles(besides: page)
        let shown = try app.shownPopupTabTitle(besides: page) ?? "none"
        let sameBrowser = peekPage.isShown && !peekPage.isClosed
        let sameDocument = try await peekPage.string("window.bowLoadID") == loadID
        let pageLoads = try await peekPage.string("String(window.bowLoads)")
        let noReload = sameDocument && pageLoads == "1" && peekPage.finishedLoads == loads
        let passed = tabs == ["A", "B", "C"] && shown == "B" && sameBrowser && noReload
        run.check(
            name, passed: passed,
            "tabs=\(PeekTests.list(tabs)) shown=\(shown) same_browser=\(sameBrowser) reloaded=\(!noReload)"
                + (noReload ? "" : " loads=\(pageLoads) same_document=\(sameDocument)"))
    }
}

/// From a pinned tab, a plain click on a link to another site opens it in a Peek and the pinned tab stays on its page;
/// with the setting off the same link opens as a new tab at the top of Today instead, and the pinned tab still stays.
struct PeekPinnedTest: E2ETest {
    let name = "peek.pinned"

    func run(_ run: E2ERun) async throws {
        guard let seeder = run.app as? any E2EStoreSeedApp, let app = run.app as? any E2EPeekApp else {
            throw E2EError("the app cannot seed a sidebar or has no Peek")
        }
        defer { app.resetPeekSettings() }
        let page = try await run.step("open a window on a pinned tab", timeout: E2ETimeouts.firstLoad) {
            let seed = E2ESeed(spaces: [
                E2ESeedSpace("Home", pinned: [.tab("A", url: E2EFixture.url("peek/source.html"))])
            ])
            let page = try await seeder.openWindow(seeded: seed).page
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the pinned tab loaded with status \(status)") }
            return page
        }
        let peekPage = try await PeekTests.openPeek(run, app: app, page: page, selector: "#offsite", modifiers: [])
        let peekHost = try await peekPage.string("location.host")
        let stayedOn = try await page.string("document.title")
        let onTabs = try app.popupTabTitles(besides: page)
        try await run.step("press Escape", timeout: E2ETimeouts.step) {
            try await peekPage.press(.escape)
            _ = try await app.untilNoPeek(besides: page)
        }
        let off = try await run.step("click the link with the setting off", timeout: E2ETimeouts.firstLoad) {
            try app.setPeekSettings(shiftClick: true, offSiteLinks: false)
            try await page.click("#offsite")
            _ = try await E2EWaits.until { try app.popupTabTitles(besides: page) == ["A", "B"] }
            return (
                peek: try app.peek(besides: page) == nil ? "none" : "open",
                tabs: try app.popupTabTitles(besides: page),
                shown: try app.shownPopupTabTitle(besides: page) ?? "none"
            )
        }
        let stayedOff = try await page.string("document.title")
        let passed =
            peekHost == "other.bow.test" && stayedOn == "A" && onTabs == ["A"] && off.peek == "none"
            && off.tabs == ["A", "B"] && off.shown == "B" && stayedOff == "A"
        run.check(
            name, passed: passed,
            "on: peek=\(peekHost) pinned=\(stayedOn) tabs=\(PeekTests.list(onTabs)); "
                + "off: peek=\(off.peek) tabs=\(PeekTests.list(off.tabs)) shown=\(off.shown) pinned=\(stayedOff)")
    }
}

/// Closing the Peek's source tab closes the Peek and its browser, leaving no browser behind it.
struct PeekSourceCloseTest: E2ETest {
    let name = "peek.source_close"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PeekTests.openSource(run)
        _ = try await PeekTests.openOther(run, besides: page)
        let before = app.peekOpenBrowsers
        let peekPage = try await PeekTests.openPeek(run, app: app, page: page)
        let result = try await run.step("close the source tab", timeout: E2ETimeouts.step) {
            let closed = try await run.app.closeTab(page)
            let noPeek = try await app.untilNoPeek(besides: page)
            let pageClosed = try await E2EWaits.until { peekPage.isClosed }
            // A and B gone, C still open: one browser fewer than before the Peek opened, none left behind.
            let settled = try await E2EWaits.until { app.peekOpenBrowsers == before - 1 }
            return (closed, noPeek, pageClosed, settled, app.peekOpenBrowsers - (before - 1))
        }
        let passed = result.0 && result.1 && result.2 && result.3
        run.check(
            name, passed: passed,
            "source_closed=\(result.0) peek=\(result.1 ? "none" : "open") page_closed=\(result.2) "
                + "browsers_left=\(result.4)")
    }
}

/// Showing another tab closes the Peek and its browser.
struct PeekSwitchTest: E2ETest {
    let name = "peek.switch"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PeekTests.openSource(run)
        let other = try await PeekTests.openOther(run, besides: page)
        let peekPage = try await PeekTests.openPeek(run, app: app, page: page)
        let result = try await run.step("select tab C", timeout: E2ETimeouts.step) {
            try run.app.select(other)
            let noPeek = try await app.untilNoPeek(besides: page)
            let pageClosed = try await E2EWaits.until { peekPage.isClosed }
            return (noPeek, pageClosed, try app.shownPopupTabTitle(besides: page) ?? "none")
        }
        let tabs = try app.popupTabTitles(besides: page)
        let passed = result.0 && result.1 && result.2 == "C" && tabs == ["A", "C"]
        run.check(
            name, passed: passed,
            "peek=\(result.0 ? "none" : "open") page_closed=\(result.1) shown=\(result.2) tabs=\(PeekTests.list(tabs))")
    }
}

/// Dismissing a Peek whose page has unsaved changes asks first: Stay keeps the Peek open on the same page, and Leave
/// then closes it. The Close button and a press on the dimmed page dismiss as Escape does.
struct PeekStayTest: E2ETest {
    let name = "peek.stay"
    var checks: [String] { ["peek.stay", "peek.backdrop"] }

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PeekTests.openSource(run)
        let peekPage = try await PeekTests.openPeek(run, app: app, page: page)
        let loadID = try await run.step("type a draft", timeout: E2ETimeouts.step) {
            try await peekPage.typeLeaveDraft()
            return try await peekPage.string("window.bowLoadID")
        }
        let stay = try await run.step("Close and stay", timeout: E2ETimeouts.step) {
            peekPage.leavePromptAnswer = false
            try app.press(.close, besides: page)
            _ = try await E2EWaits.until { peekPage.leavePrompts == 1 }
            let open = try app.peek(besides: page) != nil && !peekPage.isClosed
            let same = try await peekPage.string("window.bowLoadID") == loadID
            return (open && same, peekPage.leavePrompts)
        }
        let leave = try await run.step("press the dimmed page and leave", timeout: E2ETimeouts.step) {
            peekPage.leavePromptAnswer = true
            try app.pressPeekBackdrop(besides: page)
            let gone = try await app.untilNoPeek(besides: page)
            let closed = try await E2EWaits.until { peekPage.isClosed }
            return (gone && closed, peekPage.leavePrompts)
        }
        let shown = try app.shownPopupTabTitle(besides: page) ?? "none"
        run.check(
            "peek.stay", passed: stay.0 && stay.1 == 1, "kept=\(stay.0) prompts=\(stay.1)")
        run.check(
            "peek.backdrop", passed: leave.0 && leave.1 == 2 && shown == "A",
            "closed=\(leave.0) prompts=\(leave.1) shown=\(shown)")
    }
}

/// A same-site link on a pinned tab that the server redirects to another site (a "Sign in with Google" link) stays in
/// the pinned tab: only a navigation's first ask may open a Peek, never its redirect.
struct PeekRedirectTest: E2ETest {
    let name = "peek.redirect"

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await PeekTests.openPinnedSource(run)
        let before = app.peekOpenBrowsers
        let result = try await run.step("click a same-site link that redirects off the site", timeout: E2ETimeouts.firstLoad)
        {
            try await page.click("#redirect")
            // The tab shows B once it followed the redirect; with the redirect taken for a click, a Peek opens on B
            // instead and the tab stays on A.
            _ = try await E2EWaits.until {
                try app.popupTabTitles(besides: page) == ["B"] || app.peek(besides: page) != nil
            }
            let peek = try app.peek(besides: page) == nil ? "none" : "open"
            let host = try await page.string("location.host")
            return (peek: peek, host: host, tabs: try app.popupTabTitles(besides: page))
        }
        let browsers = app.peekOpenBrowsers - before
        let passed = result.peek == "none" && result.host == "other.bow.test" && result.tabs == ["B"] && browsers == 0
        run.check(
            name, passed: passed,
            "peek=\(result.peek) pinned=\(result.host) tabs=\(PeekTests.list(result.tabs)) new_browsers=\(browsers)")
    }
}

/// Closing the window while its Peek's page has unsaved changes asks that page too and waits for its answer: Stay
/// keeps the window and the Peek open on the same page, and Leave closes the Peek and the window, leaving no browser.
struct PeekWindowCloseTest: E2ETest {
    let name = "peek.window_close"
    var checks: [String] { ["peek.window_close", "peek.window_close_leave"] }

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        guard let peekApp = run.app as? any E2EPeekApp else { throw E2EError("the app has no Peek") }
        let start = peekApp.peekOpenBrowsers
        let (app, page) = try await PeekTests.openSource(run)
        let peekPage = try await PeekTests.openPeek(run, app: app, page: page)
        try await run.step("type a draft", timeout: E2ETimeouts.step) { try await peekPage.typeLeaveDraft() }
        let baseline = app.peekOpenBrowsers
        let stay = try await run.step("close the window and stay", timeout: E2ETimeouts.step) {
            peekPage.leavePromptAnswer = false
            try edges.requestWindowClose(of: page)
            _ = try await E2EWaits.until { peekPage.leavePrompts == 1 || page.isClosed }
            // A round trip through both pages, after the answer reached the Peek's page: by then a window that went on
            // closing has closed its tab.
            let sourceTitle = page.isClosed ? nil : try? await page.string("document.title")
            let peekTitle = peekPage.isClosed ? nil : try? await peekPage.string("document.title")
            let sourceAlive = !page.isClosed && sourceTitle == "A"
            let peekAlive = !peekPage.isClosed && peekTitle == "B"
            let window = page.isClosed ? false : try edges.windowState(of: page).isOpen
            let card = page.isClosed ? nil : try app.peek(besides: page)
            return (
                window: window, card: card?.showsPage == true, source: sourceAlive, peek: peekAlive,
                prompts: peekPage.leavePrompts, browsers: app.peekOpenBrowsers - baseline
            )
        }
        run.check(
            name,
            passed: stay.window && stay.card && stay.source && stay.peek && stay.prompts == 1 && stay.browsers == 0,
            "window=\(stay.window ? "open" : "closed") card=\(stay.card ? "shown" : "none") source=\(stay.source) "
                + "peek_page=\(stay.peek) prompts=\(stay.prompts) browsers_left=\(stay.browsers)")

        let leave = try await run.step("close the window again and leave", timeout: E2ETimeouts.step) {
            peekPage.leavePromptAnswer = true
            if !page.isClosed { try edges.requestWindowClose(of: page) }
            let closed = try await E2EWaits.until {
                page.isClosed && peekPage.isClosed && app.peekOpenBrowsers == start
            }
            return (closed, page.isClosed, peekPage.isClosed, peekPage.leavePrompts, app.peekOpenBrowsers - start)
        }
        run.check(
            "peek.window_close_leave", passed: leave.0 && leave.3 == 2,
            "window=\(leave.1 ? "closed" : "open") peek_page=\(leave.2 ? "closed" : "open") prompts=\(leave.3) "
                + "browsers_left=\(leave.4)")
    }
}
