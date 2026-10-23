import Foundation

/// Tests of unloading tabs: an unloaded tab keeps its row and loads again when chosen, the setting off unloads
/// nothing, idle background tabs unload on a pass while the active and capturing tabs stay, and memory pressure
/// unloads. The unloader's clock is moved forward instead of waited on. Fixtures in E2E/Fixtures/unload/.
@MainActor
enum UnloadTests {
    static let all: [any E2ETest] = [
        UnloadEngineReloadTest(), UnloadOffTest(), UnloadPolicyTest(), UnloadExemptTest(), UnloadPressureTest(),
        UnloadDialogTest(),
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

/// With the setting off (the default), nothing runs and nothing unloads: not after a day idle, not under critical
/// memory pressure.
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

/// A background tab's alert shows as a sheet on its window: a pass while it is up unloads nothing and leaves the
/// alert for the person to answer; once it is answered, the next pass unloads the tab.
struct UnloadDialogTest: E2ETest {
    let name = "unload.dialog"

    func run(_ run: E2ERun) async throws {
        let (app, _) = try UnloadTests.apps(run)
        defer { app.resetUnloader() }
        let page = try await UnloadTests.openWindow(run, "home")
        let other = try await UnloadTests.openBackground(run, ["dialog"], besides: page)[0]
        let item = try app.unloadItem(of: other)
        try await run.step("show an alert from the background tab", timeout: E2ETimeouts.step) {
            _ = try await other.evaluate("setTimeout(() => alert('unload dialog'), 0); true")
            guard try await TabEdgesTests.until({ try app.unloadDialogShown(besides: page) }) else {
                throw E2EError("the alert never showed")
            }
        }
        let (during, duringState, sheetKept) = try await run.step("pass with the alert up", timeout: E2ETimeouts.step) {
            try app.setUnloadEnabled(true)
            try app.useManualUnloadClock()
            try app.advanceUnloadClock(by: UnloadTests.longIdle)
            let unloaded = try await app.runUnloadPass()
            return (unloaded, try app.unloadTabState(item, besides: page), try app.unloadDialogShown(besides: page))
        }
        let (after, afterState) = try await run.step("answer the alert, then pass", timeout: E2ETimeouts.step) {
            guard try app.cancelUnloadDialog(besides: page) else { throw E2EError("no alert to answer") }
            // The alert is answered once the page runs script again.
            _ = try await other.evaluate("true")
            let unloaded = try await app.runUnloadPass()
            return (unloaded, try app.unloadTabState(item, besides: page))
        }
        run.check(
            name,
            passed: during == 0 && duringState.isLoaded && sheetKept && after == 1 && !afterState.isLoaded
                && afterState.isListed,
            "with-alert=\(during) tab=\(UnloadTests.describe(duringState)) alert=\(sheetKept ? "kept" : "gone")"
                + " answered=\(after) tab=\(UnloadTests.describe(afterState))")
    }
}
