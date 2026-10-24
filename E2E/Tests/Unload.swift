import Foundation

/// Tests of unloading tabs: an unloaded tab keeps its row and loads again when chosen, the setting off unloads
/// nothing, idle background tabs unload on a pass while the active and capturing tabs stay, and memory pressure
/// unloads. The unloader's clock is moved forward instead of waited on. Fixtures in E2E/Fixtures/unload/.
@MainActor
enum UnloadTests {
    static let all: [any E2ETest] = [
        UnloadEngineReloadTest(), UnloadOffTest(), UnloadPolicyTest(), UnloadExemptTest(), UnloadPressureTest(),
        UnloadDialogTest(), UnloadOffscreenSpaceTest(), UnloadPinnedAwayTest(), UnloadTypedTest(), UnloadManyTest(),
        UnloadAudibleTest(), UnloadPlaceholderTest(),
    ]

    /// Longer than every idle limit at normal pressure, pinned tabs included.
    static let longIdle: TimeInterval = 24 * 60 * 60

    static func apps(_ run: E2ERun) throws -> (any E2EUnloadApp, any E2EWindowEdgesApp) {
        guard let unload = run.app as? any E2EUnloadApp, let edges = run.app as? any E2EWindowEdgesApp else {
            throw E2EError("the app has no tab unloader")
        }
        return (unload, edges)
    }

    static func url(_ name: String) -> URL {
        E2EFixture.url("unload/page.html?name=\(name)")
    }

    /// Opens a window on page `name` and waits for it.
    static func openWindow(_ run: E2ERun, _ name: String) async throws -> any E2EPage {
        try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: url(name))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
    }

    /// Opens background tabs on pages `names` beside `page` and waits for each to load.
    static func openBackground(_ run: E2ERun, _ names: [String], besides page: any E2EPage) async throws
        -> [any E2EPage]
    {
        try await run.step("open background tabs", timeout: E2ETimeouts.firstLoad) {
            var pages: [any E2EPage] = []
            for name in names {
                let other = try run.app.openTab(at: url(name), besides: page, select: false)
                _ = try await other.waitForLoad(after: 0)
                pages.append(other)
            }
            return pages
        }
    }

    /// How many of `items` the window lists with an open page.
    static func liveCount(_ app: any E2EUnloadApp, _ items: [String], besides page: any E2EPage) throws -> Int {
        try items.filter { try app.unloadTabState($0, besides: page).isLoaded }.count
    }

    static func describe(_ state: E2EUnloadTabState) -> String {
        state.isLoaded ? "live" : (state.isListed ? "unloaded" : "gone")
    }
}

/// Unloads a background tab through the engine, then chooses it: its row, address and title stay while it is
/// unloaded, and choosing it loads it again on its address.
struct UnloadEngineReloadTest: E2ETest {
    let name = "unload.engine_reload"

    func run(_ run: E2ERun) async throws {
        let (app, edges) = try UnloadTests.apps(run)
        let page = try await UnloadTests.openWindow(run, "home")
        let other = try await UnloadTests.openBackground(run, ["away"], besides: page)[0]
        let item = try app.unloadItem(of: other)
        try await run.step("wait for the tab's icon", timeout: E2ETimeouts.step) {
            guard try await TabEdgesTests.until({ try app.unloadTabState(item, besides: page).hasFavicon }) else {
                throw E2EError("the tab's row never showed its icon")
            }
        }
        let (unloaded, during) = try await run.step("unload through the engine", timeout: E2ETimeouts.step) {
            let unloaded = try await app.unloadThroughEngine(other)
            // The window hears of the unload on a later main thread task: wait until it has let go of the page.
            _ = try await TabEdgesTests.until { try app.unloadTabState(item, besides: page).isReleased }
            return (unloaded, try app.unloadTabState(item, besides: page))
        }
        let icon = during.hasFavicon
        let after = try await run.step("choose the unloaded tab", timeout: E2ETimeouts.firstLoad) {
            try edges.selectSavedTab(item, besides: page)
            _ = try await TabEdgesTests.until {
                let state = try app.unloadTabState(item, besides: page)
                return state.isShown && state.url == UnloadTests.url("away").absoluteString
            }
            return try app.unloadTabState(item, besides: page)
        }
        let path = URL(string: after.url).map { "\($0.path)?\($0.query ?? "")" } ?? after.url
        run.check(
            name,
            passed: unloaded && during.isListed && !during.isLoaded && icon
                && during.url == UnloadTests.url("away").absoluteString && during.title == "Unload away"
                && after.isLoaded && after.isShown && after.url == UnloadTests.url("away").absoluteString,
            "unloaded=\(unloaded) row=\(during.isListed ? "kept" : "gone") title=\"\(during.title)\""
                + " icon=\(icon ? "kept" : "gone")"
                + " reloaded=\(after.isShown) url=\(path)")
    }
}

/// With the setting turned off (it is on by default), nothing runs and nothing unloads: not after a day idle, not under
/// critical memory pressure.
struct UnloadOffTest: E2ETest {
    let name = "unload.off"

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let others = try await UnloadTests.openBackground(run, ["a", "b"], besides: page)
        let items = try ([page] + others).map { try app.unloadItem(of: $0) }
        let (running, idle, pressure, live) = try await run.step("pass with the setting off", timeout: E2ETimeouts.step)
        {
            try app.setUnloadEnabled(false)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let idle = try await app.runUnloadPass()
            let pressure = try await app.simulateMemoryPressure("critical")
            return (app.unloaderIsRunning, idle, pressure, try UnloadTests.liveCount(app, items, besides: page))
        }
        run.check(
            name, passed: !running && idle == 0 && pressure == 0 && live == items.count,
            "running=\(running) unloaded=\(idle + pressure) live=\(live)")
    }
}

/// With the setting on, a pass after a day idle unloads every background tab and keeps the active one; choosing an
/// unloaded tab loads it again on its address.
struct UnloadPolicyTest: E2ETest {
    let name = "unload.policy"
    let tags = ["smoke"]
    let checks = ["unload.policy", "unload.reload"]

    func run(_ run: E2ERun) async throws {
        let (app, edges) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let others = try await UnloadTests.openBackground(run, ["a", "b", "c"], besides: page)
        let items = try ([page] + others).map { try app.unloadItem(of: $0) }
        let (running, unloaded, live, active) = try await run.step("pass after a day idle", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let unloaded = try await app.runUnloadPass()
            return (
                app.unloaderIsRunning, unloaded, try UnloadTests.liveCount(app, items, besides: page),
                try app.unloadTabState(items[0], besides: page)
            )
        }
        let rows = try items.filter { try app.unloadTabState($0, besides: page).isListed }.count
        run.check(
            name, passed: running && unloaded == others.count && live == 1 && active.isShown && rows == items.count,
            "live=\(live) unloaded=\(unloaded) rows=\(rows) running=\(running)")

        let chosen = try await run.step("choose an unloaded tab", timeout: E2ETimeouts.firstLoad) {
            try edges.selectSavedTab(items[1], besides: page)
            _ = try await TabEdgesTests.until { try app.unloadTabState(items[1], besides: page).isShown }
            return try app.unloadTabState(items[1], besides: page)
        }
        run.check(
            "unload.reload", passed: chosen.isShown && chosen.url == UnloadTests.url("a").absoluteString,
            "shown=\(chosen.isShown) url=\(URL(string: chosen.url)?.query ?? chosen.url)")
    }
}

/// A background tab using the camera stays loaded through a pass after a day idle, as does the active tab, while
/// another background tab unloads.
struct UnloadExemptTest: E2ETest {
    let name = "unload.exempt"

    func run(_ run: E2ERun) async throws {
        let (app, edges) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let capture = try await run.step("start the camera in a tab", timeout: E2ETimeouts.firstLoad) {
            let capture = try run.app.openTab(
                at: E2EFixture.url("unload/capture.html"), besides: page, select: true)
            _ = try await capture.waitForLoad(after: 0)
            _ = try await capture.evaluate("startCamera()")
            try await capture.waitForPermissionPrompt().answer(true)
            let result = try await capture.string("window.cameraResult")
            guard result == "live" else { throw E2EError("the camera did not start: \(result)") }
            return capture
        }
        let captureItem = try app.unloadItem(of: capture)
        let other = try await UnloadTests.openBackground(run, ["other"], besides: page)[0]
        let otherItem = try app.unloadItem(of: other)
        let homeItem = try app.unloadItem(of: page)
        let states = try await run.step("pass after a day idle", timeout: E2ETimeouts.step) {
            try edges.selectSavedTab(homeItem, besides: page)
            guard try await TabEdgesTests.until({ try app.unloadTabState(captureItem, besides: page).isCapturing })
            else { throw E2EError("the camera tab does not report capturing") }
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            _ = try await app.runUnloadPass()
            return try [homeItem, captureItem, otherItem].map { try app.unloadTabState($0, besides: page) }
        }
        run.check(
            name, passed: states[0].isShown && states[1].isLoaded && !states[2].isLoaded && states[2].isListed,
            "active=\(UnloadTests.describe(states[0])) capturing=\(UnloadTests.describe(states[1]))"
                + " other=\(UnloadTests.describe(states[2]))")
    }
}

/// A pass with nothing idle unloads nothing; critical memory pressure then unloads the background tab and keeps the
/// active one.
struct UnloadPressureTest: E2ETest {
    let name = "unload.pressure"

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let other = try await UnloadTests.openBackground(run, ["b"], besides: page)[0]
        let items = try [page, other].map { try app.unloadItem(of: $0) }
        let (idle, pressure, states) = try await run.step("memory pressure", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            let idle = try await app.runUnloadPass()
            let pressure = try await app.simulateMemoryPressure("critical")
            return (idle, pressure, try items.map { try app.unloadTabState($0, besides: page) })
        }
        run.check(
            name, passed: idle == 0 && pressure == 1 && states[0].isShown && !states[1].isLoaded,
            "idle_pass=\(idle) critical=\(pressure) active=\(UnloadTests.describe(states[0]))"
                + " background=\(UnloadTests.describe(states[1]))")
    }
}

/// A background tab's alert waits for its tab to be shown (the page dialogs feature): a pass while it waits unloads
/// nothing, so the alert is not lost unseen; once the person has seen and answered it, the next pass unloads the tab.
struct UnloadDialogTest: E2ETest {
    let name = "unload.dialog"

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        let dialogs = try PageDialogsTests.dialogsApp(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let other = try await UnloadTests.openBackground(run, ["dialog"], besides: page)[0]
        let item = try app.unloadItem(of: other)
        try await run.step("alert from the background tab", timeout: E2ETimeouts.step) {
            _ = try await other.evaluate("setTimeout(() => { alert('unload dialog'); window.alerted = true }, 0); true")
            _ = try await E2EWaits.until(other, "window.alerted === true")
            guard try dialogs.pageDialogWaits(for: other) else { throw E2EError("the alert is not waiting") }
        }
        let (during, duringState, alertKept) = try await run.step(
            "pass with the alert waiting", timeout: E2ETimeouts.step
        ) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let unloaded = try await app.runUnloadPass()
            return (unloaded, try app.unloadTabState(item, besides: page), try dialogs.pageDialogWaits(for: other))
        }
        let (after, afterState) = try await run.step("see and answer the alert, then pass", timeout: E2ETimeouts.step) {
            try run.app.select(other)
            _ = try await PageDialogsTests.untilDialog(dialogs, besides: page)
            try dialogs.answerPageDialog(besides: page, accept: true, text: nil)
            try run.app.select(page)
            guard try await TabEdgesTests.until({ page.isShown }) else { throw E2EError("the first tab is not shown") }
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let unloaded = try await app.runUnloadPass()
            return (unloaded, try app.unloadTabState(item, besides: page))
        }
        run.check(
            name,
            passed: during == 0 && duringState.isLoaded && alertKept && after == 1 && !afterState.isLoaded
                && afterState.isListed,
            "with-alert=\(during) tab=\(UnloadTests.describe(duringState)) alert=\(alertKept ? "kept" : "gone")"
                + " answered=\(after) tab=\(UnloadTests.describe(afterState))")
    }
}

/// Tabs unloaded while their Space is off screen keep their rows: switching back to that Space shows a today tab and
/// a pinned tab (still on its pinned address) with their icon, address and page title, and choosing each loads it
/// again on that address.
struct UnloadOffscreenSpaceTest: E2ETest {
    let name = "unload.offscreen_space"
    let checks = ["unload.offscreen_space", "unload.offscreen_reload"]

    func run(_ run: E2ERun) async throws {
        let (app, edges) = try UnloadTests.apps(run)
        guard let seeder = run.app as? any E2EStoreSeedApp else { throw E2EError("the app cannot seed a sidebar") }
        defer { app.resetUnloader() }
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace(
                    "Away", pinned: [.tab("pin", url: UnloadTests.url("pin"))],
                    today: [.tab("home", url: UnloadTests.url("home")), .tab("bg", url: UnloadTests.url("bg"))]),
                E2ESeedSpace("Here", today: [.tab("here", url: UnloadTests.url("here"))]),
            ], activeSpace: "Here")
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await seeder.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let page = window.page
        let away = window.spaceIDs["Away"] ?? ""
        let here = window.spaceIDs["Here"] ?? ""
        let pin = window.itemIDs["pin"] ?? ""
        let bg = window.itemIDs["bg"] ?? ""
        let home = window.itemIDs["home"] ?? ""
        try await run.step("load the tabs of the other Space", timeout: E2ETimeouts.firstLoad) {
            try edges.switchToSpace(away, besides: page)
            for (item, name) in [(pin, "pin"), (bg, "bg"), (home, "home")] {
                guard try await TabEdgesTests.until({ try app.unloadTabState(item, besides: page).isListed }) else {
                    throw E2EError("tab \(name) is not listed")
                }
                try edges.selectSavedTab(item, besides: page)
                guard
                    try await TabEdgesTests.until({
                        let state = try app.unloadTabState(item, besides: page)
                        return state.isShown && state.hasFavicon && state.title == "Unload \(name)"
                    })
                else { throw E2EError("tab \(name) never showed its page and icon") }
            }
        }
        let unloaded = try await run.step("pass with that Space off screen", timeout: E2ETimeouts.step) {
            try edges.switchToSpace(here, besides: page)
            guard try await TabEdgesTests.until({ page.isShown }) else { throw E2EError("the Space did not switch") }
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            return try await app.runUnloadPass()
        }
        let rows = try await run.step("switch back", timeout: E2ETimeouts.firstLoad) {
            try edges.switchToSpace(away, besides: page)
            // Its active tab loads again; the others stay unloaded with their rows.
            _ = try await TabEdgesTests.until { try app.unloadTabState(home, besides: page).isShown }
            return try [pin, bg].map { try app.unloadTabState($0, besides: page) }
        }
        let expected = [("pin", UnloadTests.url("pin")), ("bg", UnloadTests.url("bg"))]
        let rowsRight = zip(rows, expected).allSatisfy { row, want in
            row.isListed && !row.isLoaded && row.hasFavicon && row.url == want.1.absoluteString
                && row.title == "Unload \(want.0)"
        }
        run.check(
            name, passed: unloaded == 3 && rowsRight,
            "unloaded=\(unloaded) "
                + zip(rows, expected).map { row, want in
                    "\(want.0)=\(UnloadTests.describe(row)) icon=\(row.hasFavicon) title=\"\(row.title)\""
                        + " url=\(URL(string: row.url)?.query ?? row.url)"
                }.joined(separator: " "))

        let chosen = try await run.step("choose the unloaded tabs", timeout: E2ETimeouts.firstLoad) {
            var states: [E2EUnloadTabState] = []
            for (item, want) in zip([pin, bg], expected) {
                try edges.selectSavedTab(item, besides: page)
                _ = try await TabEdgesTests.until {
                    let state = try app.unloadTabState(item, besides: page)
                    return state.isShown && state.url == want.1.absoluteString
                }
                states.append(try app.unloadTabState(item, besides: page))
            }
            return states
        }
        run.check(
            "unload.offscreen_reload",
            passed: zip(chosen, expected).allSatisfy { $0.isShown && $0.isLoaded && $0.url == $1.1.absoluteString },
            zip(chosen, expected).map { "\($1.0): shown=\($0.isShown) url=\(URL(string: $0.url)?.query ?? $0.url)" }
                .joined(separator: " "))
    }
}

/// A pinned tab browsed away from its pinned address is never unloaded (loading it again would return to the pinned
/// address and lose the page it was on), while a background today tab unloads on the same pass.
struct UnloadPinnedAwayTest: E2ETest {
    let name = "unload.pinned_away"

    func run(_ run: E2ERun) async throws {
        let (app, edges) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let other = try await UnloadTests.openBackground(run, ["other"], besides: page)[0]
        let pinned = try await run.step("pin a tab and browse away", timeout: E2ETimeouts.firstLoad) {
            let pinned = try run.app.openTab(at: UnloadTests.url("pin"), besides: page, select: true)
            _ = try await pinned.waitForLoad(after: 0)
            try edges.pin(pinned)
            let loads = pinned.finishedLoads
            try pinned.load(UnloadTests.url("moved"))
            _ = try await pinned.waitForLoad(after: loads)
            try run.app.select(page)
            return pinned
        }
        let items = try [pinned, other].map { try app.unloadItem(of: $0) }
        let (unloaded, states) = try await run.step("pass after a day idle", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let unloaded = try await app.runUnloadPass()
            return (unloaded, try items.map { try app.unloadTabState($0, besides: page) })
        }
        run.check(
            name,
            passed: unloaded == 1 && states[0].isLoaded && states[0].url == UnloadTests.url("moved").absoluteString
                && !states[1].isLoaded,
            "unloaded=\(unloaded) pinned=\(UnloadTests.describe(states[0]))"
                + " url=\(URL(string: states[0].url)?.query ?? states[0].url) other=\(UnloadTests.describe(states[1]))")
    }
}

/// Text typed into a page's field keeps the tab loaded through a pass after a day idle, with its text; once the tab
/// navigates to another page, the next pass unloads it.
struct UnloadTypedTest: E2ETest {
    let name = "unload.typed"
    let checks = ["unload.typed", "unload.typed_navigated"]

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let form = try await run.step("open the form", timeout: E2ETimeouts.firstLoad) {
            let form = try await run.app.openWindow(at: E2EFixture.url("unload/form.html"))
            _ = try await form.waitForLoad(after: 0)
            return form
        }
        let item = try app.unloadItem(of: form)
        let typed = try await run.step("type into the field", timeout: E2ETimeouts.step) {
            try await form.click("#field")
            // A page may drop the first keys after its focus changes, so a key is pressed until the field has text.
            let deadline = Date().addingTimeInterval(E2EWaits.budget())
            var value = ""
            while value.isEmpty {
                guard Date() < deadline else { throw E2EError("the field never got the typed text") }
                try await form.press(letter: "u", macKeyCode: 32, modifiers: [])
                value = try await form.string("document.getElementById('field').value")
            }
            return value
        }
        let page = try await run.step("switch to another tab", timeout: E2ETimeouts.firstLoad) {
            let page = try run.app.openTab(at: UnloadTests.url("home"), besides: form, select: true)
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let (during, duringState, kept) = try await run.step("pass after a day idle", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let unloaded = try await app.runUnloadPass()
            let state = try app.unloadTabState(item, besides: page)
            let kept = state.isLoaded ? try await form.string("document.getElementById('field').value") : ""
            return (unloaded, state, kept)
        }
        run.check(
            name, passed: during == 0 && duringState.isLoaded && kept == typed,
            "unloaded=\(during) tab=\(UnloadTests.describe(duringState)) text=\"\(kept)\" typed=\"\(typed)\"")

        let (after, afterState) = try await run.step("navigate it, then pass", timeout: E2ETimeouts.firstLoad) {
            let loads = form.finishedLoads
            try form.load(UnloadTests.url("after"))
            _ = try await form.waitForLoad(after: loads)
            let unloaded = try await app.runUnloadPass()
            return (unloaded, try app.unloadTabState(item, besides: page))
        }
        run.check(
            "unload.typed_navigated", passed: after == 1 && !afterState.isLoaded && afterState.isListed,
            "unloaded=\(after) tab=\(UnloadTests.describe(afterState))")
    }
}

/// Thirty tabs in one window, one shown, at normal memory pressure with the default numbers: a pass 59 minutes on
/// unloads nothing (no count limit at normal pressure, and the idle limit is an hour), and a pass 61 minutes on
/// unloads every background tab, leaving the shown one.
struct UnloadManyTest: E2ETest {
    let name = "unload.many"
    let checks = ["unload"]

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let others = try await run.step("open 29 background tabs", timeout: 60) {
            // Opened together, then each waited for, so the run stays short.
            let pages = try (1...29).map {
                try run.app.openTab(at: UnloadTests.url("t\($0)"), besides: page, select: false)
            }
            for other in pages { _ = try await other.waitForLoad(after: 0) }
            return pages
        }
        let items = try ([page] + others).map { try app.unloadItem(of: $0) }
        let (early, unloaded, live, shown) = try await run.step("passes at 59 and 61 minutes", timeout: 30) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: 59 * 60)
            let early = try await app.runUnloadPass()
            try app.advanceUnloadClock(by: 2 * 60)
            let unloaded = try await app.runUnloadPass()
            return (
                early, unloaded, try UnloadTests.liveCount(app, items, besides: page),
                try app.unloadTabState(items[0], besides: page).isShown
            )
        }
        run.check(
            "unload", passed: early == 0 && unloaded == 29 && live == 1 && shown,
            "live=\(live) unloaded=\(unloaded)" + (early == 0 && shown ? "" : " at59=\(early) shown=\(shown)"))
    }
}

/// A background tab that played sound within the last 30 seconds stays loaded under critical memory pressure while
/// a quiet one unloads; 31 seconds after its sound stopped, the next pass unloads it. The test reports the sound
/// through the tab method the page's sound signal calls, so it chooses the moment the sound stops
/// (unload.audible_page plays real sound in a page).
struct UnloadAudibleTest: E2ETest {
    let name = "unload.audible"

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let pages = try await UnloadTests.openBackground(run, ["sound", "quiet"], besides: page)
        let items = try pages.map { try app.unloadItem(of: $0) }
        try await run.step("play and stop sound", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.setTabAudible(true, pages[0])
            guard try await TabEdgesTests.until({ try app.unloadTabState(items[0], besides: page).isAudible }) else {
                throw E2EError("the tab never reported sound")
            }
            try app.setTabAudible(false, pages[0])
            guard try await TabEdgesTests.until({ try !app.unloadTabState(items[0], besides: page).isAudible }) else {
                throw E2EError("the tab never reported its sound stopped")
            }
        }
        let (within, quiet) = try await run.step("critical pressure 20 seconds on", timeout: E2ETimeouts.step) {
            try app.advanceUnloadClock(by: 20)
            _ = try await app.simulateMemoryPressure("critical")
            return try (
                app.unloadTabState(items[0], besides: page), app.unloadTabState(items[1], besides: page)
            )
        }
        let after = try await run.step("critical pressure 31 seconds on", timeout: E2ETimeouts.step) {
            try app.advanceUnloadClock(by: 11)
            _ = try await app.simulateMemoryPressure("critical")
            return try app.unloadTabState(items[0], besides: page)
        }
        run.check(
            name, passed: within.isLoaded && !quiet.isLoaded && quiet.isListed && !after.isLoaded && after.isListed,
            "within=\(UnloadTests.describe(within)) quiet=\(UnloadTests.describe(quiet))"
                + " after=\(UnloadTests.describe(after))")
    }
}

/// Showing a tab the unloader unloaded shows the placeholder card (its title, over the page area) while its page
/// loads again, and the page once it has loaded. The page holds its load on an image the test releases, so the card
/// is seen for as long as the test needs.
struct UnloadPlaceholderTest: E2ETest {
    let name = "unload.placeholder"

    func run(_ run: E2ERun) async throws {
        let (app, edges) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let (held, key) = try await run.step("open the held page", timeout: E2ETimeouts.firstLoad) {
            let url = E2EFixture.url("unload/held.html")
            let held = try run.app.openTab(at: url, besides: page, select: false)
            // The new tab starts on a blank document whose context ends when held.html commits, so a page wait sent
            // before the commit can run in the blank document and fail with "Execution context was destroyed". The
            // load itself is held until the test releases it, so wait for the tab's own commit, not its load.
            guard try await E2EWaits.until({ held.navigationEvents.contains { $0.kind == .commit && $0.url == url } })
            else { throw E2EError("held.html never committed; events=\(held.navigationEvents)") }
            _ = try await E2EWaits.until(held, "typeof window.heldKey === 'string'")
            let key = try await held.string("window.heldKey")
            E2EFixture.releaseHeld(key)
            _ = try await held.waitForLoad(after: 0)
            return (held, key)
        }
        let item = try app.unloadItem(of: held)
        try await run.step("wait for the tab's icon", timeout: E2ETimeouts.step) {
            guard try await TabEdgesTests.until({ try app.unloadTabState(item, besides: page).hasFavicon }) else {
                throw E2EError("the tab's row never showed its icon")
            }
        }
        let unloaded = try await run.step("unload it", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            return try await app.runUnloadPass()
        }
        // The next load of the page holds on the next key.
        let number = Int(key.split(separator: "-").last ?? "") ?? 0
        let nextKey = "unload-held-\(number + 1)"
        let card = try await run.step("show the unloaded tab", timeout: E2ETimeouts.firstLoad) {
            try edges.selectSavedTab(item, besides: page)
            guard
                try await TabEdgesTests.until({
                    let card = try app.unloadPlaceholder(besides: page)
                    return card.item == item && card.inWindow
                })
            else { throw E2EError("no placeholder came up") }
            let card = try app.unloadPlaceholder(besides: page)
            let state = try app.unloadTabState(item, besides: page)
            let folder = run.outputDirectory.appendingPathComponent("unload")
            try app.writeWindowScreenshot(besides: page, to: folder.appendingPathComponent("placeholder.png"))
            return (card, state)
        }
        let (after, afterState) = try await run.step("let the page load", timeout: E2ETimeouts.firstLoad) {
            E2EFixture.releaseHeld(nextKey)
            guard
                try await TabEdgesTests.until({
                    let card = try app.unloadPlaceholder(besides: page)
                    return card.item == nil && card.log.contains("hidden \(item) finish")
                })
            else { throw E2EError("the placeholder never went") }
            return (try app.unloadPlaceholder(besides: page), try app.unloadTabState(item, besides: page))
        }
        let shownAt = after.log.firstIndex(of: "shown \(item)") ?? -1
        let hiddenAt = after.log.firstIndex(of: "hidden \(item) finish") ?? -1
        run.check(
            name,
            passed: unloaded == 1 && card.0.title == "Unload held" && card.1.isShown && shownAt >= 0
                && hiddenAt > shownAt && afterState.isShown && afterState.isLoaded,
            "unloaded=\(unloaded) card=\"\(card.0.title)\" page=\(afterState.isShown ? "shown" : "hidden")"
                + " order=\(shownAt >= 0 && hiddenAt > shownAt ? "card,page" : after.log.joined(separator: ","))"
                + " events=\(held.navigationEvents.map(\.description).joined(separator: ","))")
    }
}
