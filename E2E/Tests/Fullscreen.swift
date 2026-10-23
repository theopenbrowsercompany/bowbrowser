import Foundation

/// Page fullscreen: a page that asks to fill the screen hides the sidebar (or the top tabs bar), drops the card's
/// inset, corners and shadow and puts the window in macOS full screen; Escape, the page's own exit, switching tabs,
/// navigating away and leaving macOS full screen restore the layout. A recorder stands in for macOS full screen, so a
/// run never takes over the display. Fixtures in E2E/Fixtures/fullscreen/.
@MainActor
enum FullscreenTests {
    static let all: [any E2ETest] = [
        FullscreenEnterTest(), FullscreenEscapeTest(), FullscreenExitTest(), FullscreenTabSwitchTest(),
        FullscreenAlreadyTest(), FullscreenNavigateTest(), FullscreenWindowExitTest(), FullscreenTopTabsTest(),
    ]

    typealias App = any E2EFullscreenApp & E2ETopTabsApp & E2EDesignApp

    static func app(_ run: E2ERun) throws -> App {
        guard let app = run.app as? App else { throw E2EError("the app has no page fullscreen hooks") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("fullscreen/\(name)") }

    /// Opens a window on the player page with the window's full screen recorded.
    static func open(_ run: E2ERun, _ app: App, startingFullScreen: Bool = false) async throws -> any E2EPage {
        try await run.step("open the player page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: url("video.html"))
            _ = try await page.waitForLoad(after: 0)
            try app.recordWindowFullScreen(of: page, startingFullScreen: startingFullScreen)
            return page
        }
    }

    /// Clicks the page's Fullscreen button (a user gesture, which the Fullscreen API needs) and waits until the page
    /// is fullscreen and the window has followed.
    static func enter(_ run: E2ERun, _ app: App, _ page: any E2EPage) async throws -> E2EFullscreenState {
        try await run.step("click Fullscreen", timeout: E2ETimeouts.step) {
            try await page.click("#go")
            try await E2EWaits.until(page, "window.fullscreenEvents.includes('enter')")
            return try await E2EWaits.value({ try app.fullscreenState(of: page) }, until: \.pageFills)
        }
    }

    /// Waits until the window has restored its layout, and returns what it shows then.
    static func restored(_ app: App, _ page: any E2EPage) async throws -> E2EFullscreenState {
        try await E2EWaits.value({ try app.fullscreenState(of: page) }, until: { !$0.pageFills })
    }
}

/// A click on the page's fullscreen button hides the sidebar, lets the card fill the window and enters macOS full
/// screen once.
struct FullscreenEnterTest: E2ETest {
    let name = "fullscreen"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app)
        let state = try await FullscreenTests.enter(run, app, page)
        let element = try await page.string("document.fullscreenElement?.id ?? 'none'")
        run.check(
            name, passed: state.fillsWindow && state.toggles == 1 && state.windowFullScreen && element == "player",
            "\(state) element=\(element)")
    }
}

/// Escape leaves page fullscreen (the page never sees the key) and restores the sidebar, the card and the window.
struct FullscreenEscapeTest: E2ETest {
    let name = "fullscreen.escape"

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app)
        _ = try await FullscreenTests.enter(run, app, page)
        let result = try await run.step("press Escape", timeout: E2ETimeouts.step) {
            try await page.press(.escape)
            try await E2EWaits.until(page, "window.fullscreenEvents.includes('exit')")
            let state = try await FullscreenTests.restored(app, page)
            return (state, try await page.evaluate("window.keyDowns") as? [String] ?? [])
        }
        run.check(
            name,
            passed: result.0.restoredSidebarLayout && result.0.toggles == 2 && !result.0.windowFullScreen
                && !result.1.contains("Escape"),
            "\(result.0) page-keys=\(result.1)")
    }
}

/// The page's own `document.exitFullscreen()` restores the layout and takes the window out of full screen.
struct FullscreenExitTest: E2ETest {
    let name = "fullscreen.exit"

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app)
        _ = try await FullscreenTests.enter(run, app, page)
        let state = try await run.step("exit from the page", timeout: E2ETimeouts.step) {
            _ = try await page.evaluate("document.exitFullscreen().then(() => true)")
            return try await FullscreenTests.restored(app, page)
        }
        run.check(
            name, passed: state.restoredSidebarLayout && state.toggles == 2 && !state.windowFullScreen, "\(state)")
    }
}

/// Switching to another tab while a page is fullscreen asks that page to leave and restores the layout; going back to
/// it shows it out of fullscreen, with no second entry.
struct FullscreenTabSwitchTest: E2ETest {
    let name = "fullscreen.tab_switch"

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app)
        let other = try app.openTab(at: FullscreenTests.url("video.html?other"), besides: page, select: false)
        _ = try await FullscreenTests.enter(run, app, page)
        let switched = try await run.step("switch to the other tab", timeout: E2ETimeouts.step) {
            try app.select(other)
            return try await FullscreenTests.restored(app, page)
        }
        let back = try await run.step("switch back", timeout: E2ETimeouts.step) {
            try app.select(page)
            try await E2EWaits.until(page, "document.fullscreenElement === null")
            return try app.fullscreenState(of: page)
        }
        run.check(
            name,
            passed: switched.restoredSidebarLayout && switched.toggles == 2 && !switched.windowFullScreen
                && back.restoredSidebarLayout && back.toggles == 2,
            "switched: \(switched) back: \(back)")
    }
}

/// A window already in macOS full screen stays there: page fullscreen hides the chrome without toggling the window,
/// and leaving it restores the sidebar and the card only.
struct FullscreenAlreadyTest: E2ETest {
    let name = "fullscreen.already"

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app, startingFullScreen: true)
        let entered = try await FullscreenTests.enter(run, app, page)
        let left = try await run.step("press Escape", timeout: E2ETimeouts.step) {
            try await page.press(.escape)
            return try await FullscreenTests.restored(app, page)
        }
        run.check(
            name,
            passed: entered.fillsWindow && entered.toggles == 0 && left.restoredSidebarLayout && left.toggles == 0
                && left.windowFullScreen,
            "entered: \(entered) left: \(left)")
    }
}

/// The page navigating to another document while fullscreen restores the layout.
struct FullscreenNavigateTest: E2ETest {
    let name = "fullscreen.navigate"

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app)
        _ = try await FullscreenTests.enter(run, app, page)
        let loads = page.finishedLoads
        let state = try await run.step("navigate away", timeout: E2ETimeouts.firstLoad) {
            _ = try await page.evaluate("location.href = 'video.html?next'; true")
            _ = try await page.waitForLoad(after: loads)
            return try await FullscreenTests.restored(app, page)
        }
        run.check(
            name, passed: state.restoredSidebarLayout && state.toggles == 2 && !state.windowFullScreen, "\(state)")
    }
}

/// Leaving macOS full screen (the green button) while a page is fullscreen makes the page leave too and restores the
/// layout, without toggling the window again.
struct FullscreenWindowExitTest: E2ETest {
    let name = "fullscreen.window_exit"

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app)
        _ = try await FullscreenTests.enter(run, app, page)
        let state = try await run.step("leave macOS full screen", timeout: E2ETimeouts.step) {
            try app.leaveWindowFullScreen(of: page)
            try await E2EWaits.until(page, "window.fullscreenEvents.includes('exit')")
            return try await FullscreenTests.restored(app, page)
        }
        run.check(
            name, passed: state.restoredSidebarLayout && state.toggles == 1 && !state.windowFullScreen, "\(state)")
    }
}

/// In the top tabs layout page fullscreen hides the tab strip and the toolbar row, and Escape brings them back with
/// the card under them.
struct FullscreenTopTabsTest: E2ETest {
    let name = "fullscreen.top_tabs"

    func run(_ run: E2ERun) async throws {
        let app = try FullscreenTests.app(run)
        let page = try await FullscreenTests.open(run, app)
        defer { try? app.forgetWindowLayout() }
        try await run.step("choose Use Top Tabs", timeout: E2ETimeouts.step) {
            try app.chooseUseTopTabs(in: page)
            _ = try await E2EWaits.value({ try app.fullscreenState(of: page) }, until: \.topBarShown)
        }
        let entered = try await FullscreenTests.enter(run, app, page)
        let left = try await run.step("press Escape", timeout: E2ETimeouts.step) {
            try await page.press(.escape)
            return try await FullscreenTests.restored(app, page)
        }
        run.check(
            name,
            passed: entered.fillsWindow && left.topBarShown && left.sidebarHidden
                && left.pageInsets == [90, 8, 8, 8] && left.pageRadius == 10 && left.hasShadow && left.toggles == 2,
            "entered: \(entered) left: \(left)")
    }
}
