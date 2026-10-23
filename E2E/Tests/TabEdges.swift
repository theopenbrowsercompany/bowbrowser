import Foundation

/// Tests of the window's edges around closing, selecting and saving tabs: an empty Space keeps its window, a lone
/// pinned tab unloads and stays, a closing window loads nothing, a tab that cannot load leaves the selection as it
/// was, a page whose row left the store closes, and page titles are written to the sidebar file once they settle.
/// Fixtures in E2E/Fixtures/tabs/.
@MainActor
enum TabEdgesTests {
    static let all: [any E2ETest] = [
        TabsLastClosedTest(), TabsPinnedCloseTest(), TabsCloseWhileClosingTest(), TabsSelectFailedTest(),
        TabsOrphanClosedTest(), TabsRecordDebouncedTest(),
    ]

    static func edges(_ run: E2ERun) throws -> E2EWindowEdges {
        guard let app = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no window edges") }
        return app.windowEdges
    }

    static func url(_ name: String) -> URL {
        E2EFixture.url("tabs/counter.html?name=\(name)")
    }

    /// Opens a window on `name` and waits for its page.
    static func openWindow(_ run: E2ERun, _ name: String) async throws -> any E2EPage {
        try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: url(name))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
    }

    /// Waits until `condition` holds, or the step's wait budget runs out.
    static func until(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try condition()
    }
}

/// Closes a window's only tab: the window and its Space stay open on the empty state. Then switches to a new empty
/// Space from a Space with a page: the empty state shows, never the other Space's page.
struct TabsLastClosedTest: E2ETest {
    let name = "tabs.last_closed"
    let checks = ["tabs.last_closed", "tabs.empty_space"]

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let page = try await TabEdgesTests.openWindow(run, "last")
        let afterClose = try await run.step("close the last tab", timeout: E2ETimeouts.step) {
            guard try await run.app.closeTab(page) else { throw E2EError("the tab stayed open") }
            _ = try await TabEdgesTests.until { try edges.state(of: page).showsEmptyState }
            return try edges.state(of: page)
        }
        run.check(
            name, passed: afterClose.isOpen && afterClose.showsEmptyState && !afterClose.showsPage,
            "windows=\(afterClose.isOpen ? 1 : 0) empty_state=\(afterClose.showsEmptyState ? "shown" : "hidden")"
                + " page=\(afterClose.showsPage ? "shown" : "none")")

        let other = try await run.step("open a page again", timeout: E2ETimeouts.firstLoad) {
            let other = try edges.openTab(at: TabEdgesTests.url("again"), besides: page)
            _ = try await other.waitForLoad(after: 0)
            return other
        }
        let switched = try await run.step("switch to an empty Space", timeout: E2ETimeouts.step) {
            let shownBefore = try edges.state(of: other).showsEmptyState
            _ = try edges.createSpace(besides: other, profileID: edges.profileID(of: other))
            return (shownBefore, try edges.state(of: other), other.isShown)
        }
        let (shownBefore, state, pageShown) = switched
        run.check(
            "tabs.empty_space",
            passed: !shownBefore && state.showsEmptyState && !state.showsPage && !pageShown,
            "empty_state=\(state.showsEmptyState ? "shown" : "hidden") previous_page=\(pageShown ? "shown" : "hidden")"
                + " before=\(shownBefore ? "shown" : "hidden")")
    }
}

/// Pins a window's only tab and presses Command-W: the tab unloads and stays, active, and does not load again; the
/// window stays open.
struct TabsPinnedCloseTest: E2ETest {
    let name = "tabs.pinned_close"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        guard let sidebar = run.app as? any E2ESidebarApp else { throw E2EError("the app has no sidebar") }
        let page = try await TabEdgesTests.openWindow(run, "pinned")
        let state = try await run.step("close the pinned tab", timeout: E2ETimeouts.step) {
            try edges.pin(page)
            try sidebar.chooseMenuItem(commandKey: "w", in: page)
            guard try await TabEdgesTests.until({ page.isClosed }) else { throw E2EError("the tab did not unload") }
            // Long enough for a reload to have started.
            try await Task.sleep(nanoseconds: 300_000_000)
            return try edges.state(of: page)
        }
        run.check(
            name, passed: state.isOpen && state.rowCount == 1 && state.loadedCount == 0 && state.activeItem != nil,
            "rows=\(state.rowCount) loaded=\(state.loadedCount) window=\(state.isOpen ? "open" : "closed")"
                + " active=\(state.activeItem == nil ? "none" : "pinned")")
    }
}

/// Closes a tab and, before it has closed, its window: the window closes with it and never loads the saved tab
/// that would have followed.
struct TabsCloseWhileClosingTest: E2ETest {
    let name = "tabs.close_while_closing"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let page = try await TabEdgesTests.openWindow(run, "closing")
        let loadedNext = try await run.step("close the tab, then the window", timeout: E2ETimeouts.step) {
            let saved = try edges.insertSavedTab(TabEdgesTests.url("next"), besides: page, title: "next")
            let app = run.app
            let close = Task { try await app.closeTab(page) }
            try await run.app.closeWindow(of: page)
            _ = try await close.value
            let state = try edges.state(of: page)
            return (saved, state)
        }
        let (_, state) = loadedNext
        run.check(
            name, passed: !state.isOpen && state.loadedCount == 0,
            "window=\(state.isOpen ? "open" : "closed") loaded_next=\(state.loadedCount)")
    }
}

/// Switches a window to a Space whose profile the engine does not have, so its tabs cannot load, and selects
/// another of its tabs: the active tab stays as it was and the page area shows no page, in agreement.
struct TabsSelectFailedTest: E2ETest {
    let name = "tabs.select_failed"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let page = try await TabEdgesTests.openWindow(run, "home")
        let result = try await run.step("select a tab that cannot load", timeout: E2ETimeouts.step) {
            let space = try edges.createSpace(besides: page, profileID: "e2e-missing")
            let first = try edges.insertSavedTab(TabEdgesTests.url("p"), besides: page, title: "p")
            let second = try edges.insertSavedTab(TabEdgesTests.url("q"), besides: page, title: "q")
            try edges.selectSavedTab(first, besides: page)
            let before = try edges.state(of: page)
            try edges.selectSavedTab(second, besides: page)
            return (space, first, before, try edges.state(of: page))
        }
        let (_, first, before, after) = result
        let unchanged = after.activeItem == before.activeItem && after.activeItem == first
        run.check(
            name, passed: unchanged && !after.showsPage && !page.isShown,
            "active=\(unchanged ? "unchanged" : "moved") page=\(after.showsPage ? "shown" : "none")")
    }
}

/// Opens a page in a second Space, goes back to the first and deletes the second: the page whose row left the
/// store closes.
struct TabsOrphanClosedTest: E2ETest {
    let name = "tabs.orphan_closed"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let page = try await TabEdgesTests.openWindow(run, "stays")
        let (space, other) = try await run.step("open a page in another Space", timeout: E2ETimeouts.firstLoad) {
            let space = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            let other = try edges.openTab(at: TabEdgesTests.url("orphan"), besides: page)
            _ = try await other.waitForLoad(after: 0)
            try run.app.select(page)
            return (space, other)
        }
        let closed = try await run.step("delete the other Space", timeout: E2ETimeouts.step) {
            try edges.deleteSpace(space, besides: page)
            return try await TabEdgesTests.until { other.isClosed }
        }
        run.check(
            name, passed: closed && !page.isClosed,
            "orphan=\(closed ? "closed" : "running") kept=\(page.isClosed ? "closed" : "running")")
    }
}

/// Changes a page's title several times after it loaded: the sidebar file is not written for each change, and
/// holds the last title shortly after.
struct TabsRecordDebouncedTest: E2ETest {
    let name = "tabs.record_debounced"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let page = try await TabEdgesTests.openWindow(run, "record")
        let early = try await run.step("change the title", timeout: E2ETimeouts.step) {
            for index in 1...5 {
                _ = try await page.evaluate("document.title = 'bow-record-\(index)'")
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            guard let sidebar = run.app as? any E2ESidebarApp else { throw E2EError("the app has no sidebar") }
            guard try await TabEdgesTests.until({ try sidebar.sidebarRows(of: page).first?.title == "bow-record-5" })
            else { throw E2EError("the row never showed the last title") }
            return try edges.sidebarFile(of: page).contains("bow-record-")
        }
        let late = try await run.step("wait for the write", timeout: E2ETimeouts.step) {
            try await TabEdgesTests.until { try edges.sidebarFile(of: page).contains("bow-record-5") }
        }
        run.check(
            name, passed: !early && late,
            "written_at_once=\(early ? "yes" : "no") written_later=\(late ? "yes" : "no")")
    }
}
