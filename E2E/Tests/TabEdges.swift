import Foundation

/// Tests of the window's edges around closing, selecting and saving tabs: an empty Space keeps its window, a lone
/// pinned tab unloads and stays, a closing window loads nothing, a tab that cannot load leaves the selection as it
/// was, a page whose row left the store closes, and page titles are written to the sidebar file once they settle.
/// Fixtures in E2E/Fixtures/tabs/.
@MainActor
enum TabEdgesTests {
    static let all: [any E2ETest] = [
        TabsLastClosedTest(), TabsPinnedCloseTest(), TabsCloseWhileClosingTest(), TabsSelectFailedTest(),
        TabsOrphanClosedTest(), TabsRecordDebouncedTest(), TabsOrphanAskedOnceTest(), TabsWindowCloseStayTest(),
        TabsLinkWhileClosingTest(),
    ]

    static func edges(_ run: E2ERun) throws -> any E2EWindowEdgesApp {
        guard let app = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no window edges") }
        return app
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

    /// Opens the leave prompt fixture in a new tab of `page`'s window and types a draft into it, so closing it asks.
    static func openDraft(_ run: E2ERun, besides page: any E2EPage) async throws -> any E2EPage {
        try await run.step("open a draft", timeout: E2ETimeouts.firstLoad) {
            let draft = try run.app.openTab(at: E2EFixture.url("tabs/leave.html"), besides: page, select: true)
            _ = try await draft.waitForLoad(after: 0)
            try await draft.typeLeaveDraft()
            return draft
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
            _ = try await TabEdgesTests.until { try edges.windowState(of: page).showsEmptyState }
            return try edges.windowState(of: page)
        }
        run.check(
            name, passed: afterClose.isOpen && afterClose.showsEmptyState && !afterClose.showsPage,
            "windows=\(afterClose.isOpen ? 1 : 0) empty_state=\(afterClose.showsEmptyState ? "shown" : "hidden")"
                + " page=\(afterClose.showsPage ? "shown" : "none")")

        let other = try await run.step("open a page again", timeout: E2ETimeouts.firstLoad) {
            let other = try run.app.openTab(at: TabEdgesTests.url("again"), besides: page, select: true)
            _ = try await other.waitForLoad(after: 0)
            return other
        }
        let switched = try await run.step("switch to an empty Space", timeout: E2ETimeouts.step) {
            let shownBefore = try edges.windowState(of: other).showsEmptyState
            _ = try edges.createSpace(besides: other, profileID: edges.profileID(of: other))
            return (shownBefore, try edges.windowState(of: other), other.isShown)
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
/// window stays open on the unloaded tab state. Switching to another Space and back keeps it unloaded, and its Load
/// Tab button loads it.
struct TabsPinnedCloseTest: E2ETest {
    let name = "tabs.pinned_close"
    let checks = ["tabs.pinned_close", "tabs.pinned_space_switch"]

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
            return try edges.windowState(of: page)
        }
        run.check(
            name,
            passed: state.isOpen && state.rowCount == 1 && state.loadedCount == 0 && state.activeItem != nil
                && state.showsUnloadedTab,
            "rows=\(state.rowCount) loaded=\(state.loadedCount) window=\(state.isOpen ? "open" : "closed")"
                + " active=\(state.activeItem == nil ? "none" : "pinned")"
                + " load_button=\(state.showsUnloadedTab ? "shown" : "hidden")")

        let (back, loaded) = try await run.step("switch Space and back, then load", timeout: E2ETimeouts.firstLoad) {
            let home = try edges.activeSpace(besides: page)
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            try edges.switchToSpace(home, besides: page)
            try await Task.sleep(nanoseconds: 300_000_000)
            let back = try edges.windowState(of: page)
            try edges.clickLoadTab(besides: page)
            let loaded = try await TabEdgesTests.until { try edges.windowState(of: page).showsPage }
            return (back, loaded)
        }
        run.check(
            "tabs.pinned_space_switch",
            passed: back.loadedCount == 0 && back.showsUnloadedTab && back.activeItem == state.activeItem && loaded,
            "loaded_after_switch=\(back.loadedCount) load_button=\(back.showsUnloadedTab ? "shown" : "hidden")"
                + " load_tab=\(loaded ? "loaded" : "not loaded")")
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
            let state = try edges.windowState(of: page)
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
            let before = try edges.windowState(of: page)
            try edges.selectSavedTab(second, besides: page)
            return (space, first, before, try edges.windowState(of: page))
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
            let other = try run.app.openTab(at: TabEdgesTests.url("orphan"), besides: page, select: true)
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

/// Changes a page's title several times after it loaded: the sidebar file is not written for each change, and is
/// written once, no sooner than the save delay after the first change, holding the last title. Waits first for the
/// write of the load itself to land and settle, so a slow machine cannot mistake that write for an early one. The five
/// changes run in one page script, so they reach the app well within the delay even under load. E2e runs
/// shorten the save delay (E2EAppAdapter), so all of this takes a fraction of a second.
struct TabsRecordDebouncedTest: E2ETest {
    let name = "tabs.record_debounced"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let delay = edges.recordSaveDelay
        let page = try await TabEdgesTests.openWindow(run, "record")
        let settled = try await run.step("wait for the load's write", timeout: E2ETimeouts.step) {
            // Records wait for the load to settle, so once the file holds the loaded page's title no write is pending;
            // half a save delay without a change more covers a write still landing.
            var last = try edges.sidebarFileModified(of: page)
            var since = Date()
            let found = try await TabEdgesTests.until {
                let now = try edges.sidebarFileModified(of: page)
                if now != last {
                    last = now
                    since = Date()
                }
                guard now != nil, Date().timeIntervalSince(since) > delay / 2 else { return false }
                return try edges.sidebarFile(of: page).contains("Tab record")
            }
            guard found else { throw E2EError("the sidebar file never settled on the loaded page's title") }
            return last
        }
        let (start, burst, writes, firstHeldLast) = try await run.step("change the title", timeout: E2ETimeouts.step) {
            let start = Date()
            var writes: [Date] = []
            // Whether the file already held the last title when the first write showed.
            var firstHeldLast = false
            var last = settled
            @MainActor func note() throws {
                let now = try edges.sidebarFileModified(of: page)
                if let now, now != last {
                    if writes.isEmpty { firstHeldLast = try edges.sidebarFile(of: page).contains("bow-record-5") }
                    writes.append(now)
                    last = now
                }
            }
            // All five changes in one script, each in its own task, so they land within milliseconds of each other
            // however loaded the machine is; the app's timer starts at the first and the others do not reset it.
            let burst =
                try await page.evaluate(
                    """
                    new Promise(done => {
                      const started = performance.now();
                      let index = 0;
                      const next = () => {
                        document.title = 'bow-record-' + (++index);
                        if (index < 5) setTimeout(next, 0); else done((performance.now() - started) / 1000);
                      };
                      next();
                    })
                    """) as? Double ?? -1
            try note()
            let written = try await TabEdgesTests.until {
                try note()
                return try edges.sidebarFile(of: page).contains("bow-record-5")
            }
            guard written else { throw E2EError("the sidebar file never held the last title") }
            // Every change came before the write, so a write per change would have shown by now; half a save delay
            // more catches a late one.
            try await Task.sleep(nanoseconds: UInt64(delay / 2 * 1_000_000_000))
            try note()
            return (start, burst, writes, firstHeldLast)
        }
        let first = writes.first.map { $0.timeIntervalSince(start) } ?? -1
        let detail =
            "writes=\(writes.count) first_write_after=\(String(format: "%.2f", first))s"
            + " burst=\(String(format: "%.3f", burst))s delay=\(delay)s"
        // A little slack for the file system's clock against this one. A write sooner than the delay is the app's
        // fault however the changes landed.
        let soonEnough = first >= delay - 0.05
        // A correct app writes again only for a change that reached it after its first write: then the burst outran
        // the delay, which says nothing about the debounce, so the test stops as a setup failure instead of judging.
        if soonEnough, writes.count > 1, !firstHeldLast {
            throw E2EError(
                "setup: the last title change reached the app after its first write, so the count proves nothing"
                    + " (\(detail))")
        }
        run.check(name, passed: writes.count == 1 && soonEnough, detail)
    }
}

/// Opens a draft in a second Space, goes back to the first and deletes the second, answering stay: the page whose row
/// left is asked once, and later sidebar changes do not ask it again.
struct TabsOrphanAskedOnceTest: E2ETest {
    let name = "tabs.orphan_asked_once"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let page = try await TabEdgesTests.openWindow(run, "home")
        let home = try edges.activeSpace(besides: page)
        let space = try await run.step("create a Space", timeout: E2ETimeouts.step) {
            try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
        }
        let draft = try await TabEdgesTests.openDraft(run, besides: page)
        let prompts = try await run.step("delete the Space and stay", timeout: E2ETimeouts.step) {
            try edges.switchToSpace(home, besides: page)
            draft.leavePromptAnswer = false
            try edges.deleteSpace(space, besides: page)
            guard try await TabEdgesTests.until({ draft.leavePrompts == 1 }) else {
                throw E2EError("the orphan was not asked (\(draft.isClosed ? "it closed" : "it is still open"))")
            }
            // Later changes: a saved tab, another Space, a switch back.
            _ = try edges.insertSavedTab(TabEdgesTests.url("later"), besides: page, title: "later")
            _ = try edges.createSpace(besides: page, profileID: edges.profileID(of: page))
            try edges.switchToSpace(home, besides: page)
            try await Task.sleep(nanoseconds: 500_000_000)
            return draft.leavePrompts
        }
        run.check(name, passed: prompts == 1, "prompts=\(prompts)")
    }
}

/// Closes a window with a draft and a plain tab, answering stay: the window stays open on the draft, the page the
/// person stayed on, not the closed active tab. Closing it again and answering leave closes it.
struct TabsWindowCloseStayTest: E2ETest {
    let name = "tabs.window_close_stay"
    let checks = ["tabs.window_close_stay", "tabs.window_close_again"]

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        let plain = try await TabEdgesTests.openWindow(run, "plain")
        let draft = try await TabEdgesTests.openDraft(run, besides: plain)
        let stayed = try await run.step("close the window and stay", timeout: E2ETimeouts.step) {
            try run.app.select(plain)
            draft.leavePromptAnswer = false
            try edges.requestWindowClose(of: plain)
            let settled = try await TabEdgesTests.until { plain.isClosed && draft.leavePrompts == 1 && draft.isShown }
            guard settled else {
                throw E2EError("plain=\(plain.isClosed ? "closed" : "open") prompts=\(draft.leavePrompts)")
            }
            // Long enough for a reload of the closed tab to have started.
            try await Task.sleep(nanoseconds: 300_000_000)
            return try edges.windowState(of: draft)
        }
        run.check(
            name,
            passed: stayed.isOpen && stayed.rowCount == 2 && stayed.loadedCount == 1 && draft.isShown
                && stayed.activeTitle == "Unsaved draft",
            "window=\(stayed.isOpen ? "open" : "closed") rows=\(stayed.rowCount) loaded=\(stayed.loadedCount)"
                + " shown=\(draft.isShown ? "draft" : "other") active=\"\(stayed.activeTitle)\"")

        let closed = try await run.step("close the window again and leave", timeout: E2ETimeouts.step) {
            draft.leavePromptAnswer = true
            try await run.app.closeWindow(of: draft)
            return try edges.windowState(of: draft)
        }
        run.check(
            "tabs.window_close_again", passed: !closed.isOpen && draft.isClosed && draft.leavePrompts == 2,
            "window=\(closed.isOpen ? "open" : "closed") prompts=\(draft.leavePrompts)")
    }
}

/// Asks the last used window to close and, before it has, delivers a link: the link opens in the other window, and
/// the closing window still closes.
struct TabsLinkWhileClosingTest: E2ETest {
    let name = "tabs.link_while_closing"

    func run(_ run: E2ERun) async throws {
        let edges = try TabEdgesTests.edges(run)
        guard let store = run.app as? any E2EStoreApp else { throw E2EError("the app has no store") }
        let other = try await TabEdgesTests.openWindow(run, "other")
        let last = try await TabEdgesTests.openWindow(run, "last")
        let (link, sameAsOther) = try await run.step("close a window and deliver a link", timeout: E2ETimeouts.step) {
            try edges.requestWindowClose(of: last)
            let link = try store.openExternalLink(TabEdgesTests.url("link"))
            return (link, try edges.sameWindow(link, other))
        }
        let closed = try await run.step("wait for the window to close", timeout: E2ETimeouts.step) {
            try await TabEdgesTests.until { try !edges.windowState(of: last).isOpen }
        }
        run.check(
            name, passed: sameAsOther && closed && !link.isClosed,
            "link=\(sameAsOther ? "other window" : "closing window") closing_window=\(closed ? "closed" : "open")")
    }
}
