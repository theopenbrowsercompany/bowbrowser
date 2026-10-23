import AppKit

/// Little Arc: a link from another app opens in a small floating window instead of the browser window, its page moves
/// into a chosen Space with one key and keeps running, and closing Little Arc closes its page. With the setting off,
/// links open in the browser window as before. Fixtures in E2E/Fixtures/littlearc/.
@MainActor
enum LittleArcAreaTests {
    static let all: [any E2ETest] = [
        LittleArcPromoteTest(), LittleArcCloseTest(), LittleArcOffTest(), LittleArcNoWindowTest(),
        LittleArcDialogTest(), LittleArcPermissionTest(), LittleArcMenuTest(), LittleArcLastWindowTest(),
        LittleArcLastWindowThenCloseTest(), LittleArcAdoptFailTest(),
    ]

    /// The seed most Little Arc tests start from: Home on screen with one tab, and Work, both in the test's profile.
    static let homeAndWork = E2ESeed(
        spaces: [
            E2ESeedSpace("Home", today: [.tab("home", url: url("home"))]),
            E2ESeedSpace("Work", today: [.tab("work", url: url("work"))]),
        ],
        activeSpace: "Home")

    /// Turns Little Arc on, opens the window `seed` describes with its page loaded and opens the link intake.
    static func openWindow(_ app: any E2ELittleArcApp & E2EStoreSeedApp & E2ELinksApp, _ run: E2ERun, seed: E2ESeed)
        async throws -> any E2EPage
    {
        try app.setLittleArcSetting(true)
        return try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            try openIntake(app)
            return window.page
        }
    }

    /// Delivers a link to `name`'s page (or `url`) and returns the Little Arc window it opened, its page loaded.
    static func deliver(_ app: any E2ELittleArcApp, _ run: E2ERun, _ url: URL) async throws -> E2ELittleArcWindow {
        try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            guard let window = try app.deliverLinkToLittleArc(url) else {
                throw E2EError("the link opened no Little Arc window")
            }
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
    }

    static func url(_ name: String) -> URL { E2EFixture.url("littlearc/page.html?name=\(name)") }

    static func app(_ run: E2ERun) throws -> any E2ELittleArcApp & E2EStoreSeedApp & E2ELinksApp {
        guard let app = run.app as? any E2ELittleArcApp & E2EStoreSeedApp & E2ELinksApp else {
            throw E2EError("the app has no Little Arc")
        }
        return app
    }

    /// Opens the app's link intake, as launch does once its first window is open (an e2e run keeps every link until a
    /// test asks), so the links the test delivers open at once. Throws when a link was still kept: none is, unless a
    /// test with early links ran out of order.
    static func openIntake(_ app: any E2ELinksApp) throws {
        let kept = try app.openKeptLinks()
        guard kept.isEmpty else { throw E2EError("\(kept.count) kept links opened") }
    }

    /// What is wrong with the Little Arc window `state` as a freshly opened one, or nil: a floating panel off every
    /// screen and never key, showing its page, with its compact toolbar naming the page's host.
    static func problems(of state: E2ELittleArcWindowState, spaces: [String]) -> String? {
        var problems: [String] = []
        if !state.isFloatingPanel { problems.append("not a floating panel") }
        if state.intrudes { problems.append("on screen or key at \(state.frame)") }
        if !state.showsPage { problems.append("the page is not shown") }
        if state.toolbarHost != "bow.test" { problems.append("toolbar host \"\(state.toolbarHost)\"") }
        if !state.openEnabled { problems.append("Open in Bow is disabled") }
        if state.moveSpaces != spaces { problems.append("move menu \(state.moveSpaces)") }
        return problems.isEmpty ? nil : problems.joined(separator: ", ")
    }
}

/// With the setting at its default (on), a link from another app opens in one Little Arc window, a floating panel
/// with a compact toolbar, and the browser window is left as it was. Ctrl+2 in Little Arc then moves the page into
/// the second Space, Work: the window shows Work with the page, Little Arc is gone, and the page did not reload.
struct LittleArcPromoteTest: E2ETest {
    let name = "little-arc"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        try app.setLittleArcSetting(nil)
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace("Home", today: [.tab("home", url: LittleArcAreaTests.url("home"))]),
                E2ESeedSpace("Work", today: [.tab("work", url: LittleArcAreaTests.url("work"))]),
            ],
            activeSpace: "Home")
        let main = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            try LittleArcAreaTests.openIntake(app)
            return window.page
        }
        let before = try app.browserWindowState(of: main)

        let littleArc = try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            guard let window = try app.deliverLinkToLittleArc(LittleArcAreaTests.url("link")) else {
                throw E2EError("the link opened no Little Arc window")
            }
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let windows = try app.littleArcWindows()
        let windowResult: String
        if windows.count != 1 {
            windowResult = "\(windows.count)_windows"
        } else if let problem = LittleArcAreaTests.problems(of: windows[0], spaces: ["Home", "Work"]) {
            windowResult = problem
        } else {
            windowResult = "mini"
        }
        let page = littleArc.page
        let loadID = try await page.string("window.bowLoadID")
        let afterLink = try app.browserWindowState(of: main)
        let mainUnchanged = afterLink == before

        let promote = try await run.step("move the page into Work", timeout: E2ETimeouts.step) {
            guard try app.pressKey("2", modifiers: .control, inLittleArc: littleArc) else {
                return "Ctrl+2 was not taken"
            }
            try await app.untilNoLittleArc()
            var problems: [String] = []
            let space = try app.spaceTitle(holding: page, in: main)
            if space != "Work" { problems.append("the page is in \(space ?? "no Space on screen")") }
            if page.isClosed { problems.append("the page closed") }
            if try await page.string("window.bowLoadID") != loadID { problems.append("a new document") }
            let loads = try await page.string("sessionStorage.getItem('bowLoads')")
            if loads != "1" { problems.append("loads=\(loads)") }
            if page.finishedLoads != 1 { problems.append("finished loads=\(page.finishedLoads)") }
            let state = try app.browserWindowState(of: main)
            if state.tabs.count != 2 { problems.append("Work lists \(state.tabs.count) tabs") }
            return problems.isEmpty ? (space ?? "").lowercased() : problems.joined(separator: ", ")
        }
        run.check(
            name, passed: windowResult == "mini" && mainUnchanged && promote == "work",
            "window=\(windowResult) main_unchanged=\(mainUnchanged) promote=\(promote)"
                + (mainUnchanged ? "" : " before=\(before) after=\(afterLink)"))
    }
}

/// Closing Little Arc asks the page first: answering Stay keeps the window and its page as they were, answering
/// Leave closes both, with no browser left open and the browser window as it was.
struct LittleArcCloseTest: E2ETest {
    let name = "little-arc.close"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        try app.setLittleArcSetting(true)
        let main = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: LittleArcAreaTests.url("main"))
            _ = try await page.waitForLoad(after: 0)
            try LittleArcAreaTests.openIntake(app)
            return page
        }
        let before = try app.browserWindowState(of: main)
        let browsersBefore = app.openBrowsers

        let littleArc = try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            guard let window = try app.deliverLinkToLittleArc(LittleArcAreaTests.url("draft")) else {
                throw E2EError("the link opened no Little Arc window")
            }
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let page = littleArc.page
        let loadID = try await run.step("type a draft", timeout: E2ETimeouts.step) {
            try await page.typeLeaveDraft()
            return try await page.string("window.bowLoadID")
        }

        let stay = try await run.step("close and stay", timeout: E2ETimeouts.step) {
            page.leavePromptAnswer = false
            try app.closeLittleArc(littleArc)
            guard try await E2EWaits.until({ page.leavePrompts == 1 }) else { return "prompts=\(page.leavePrompts)" }
            var problems: [String] = []
            let windows = try app.littleArcWindows()
            if windows.count != 1 { problems.append("\(windows.count) Little Arc windows") }
            if let state = windows.first, !state.showsPage { problems.append("the page is not shown") }
            if page.isClosed { problems.append("the page closed") }
            if try await page.string("window.bowLoadID") != loadID { problems.append("a new document") }
            return problems.isEmpty ? "kept" : problems.joined(separator: ", ")
        }
        let leave = try await run.step("close and leave", timeout: E2ETimeouts.step) {
            page.leavePromptAnswer = true
            try app.closeLittleArc(littleArc)
            try await app.untilNoLittleArc()
            var problems: [String] = []
            if !(try await E2EWaits.until { page.isClosed }) { problems.append("the page stayed open") }
            if page.leavePrompts != 2 { problems.append("prompts=\(page.leavePrompts)") }
            let left = try await E2EWaits.value({ app.openBrowsers - browsersBefore }, until: { $0 <= 0 })
            if left > 0 { problems.append("browsers_left=\(left)") }
            return problems.isEmpty ? "closed" : problems.joined(separator: ", ")
        }
        let after = try app.browserWindowState(of: main)
        run.check(
            name, passed: stay == "kept" && leave == "closed" && after == before,
            "stay=\(stay) leave=\(leave) main_unchanged=\(after == before)")
    }
}

/// With "links from other apps open in Little Arc" off, a link from another app opens in a new tab of the browser
/// window's Space on screen, as before, and no Little Arc window opens.
struct LittleArcOffTest: E2ETest {
    let name = "little-arc.off"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        try app.setLittleArcSetting(false)
        let main = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: LittleArcAreaTests.url("main"))
            _ = try await page.waitForLoad(after: 0)
            try LittleArcAreaTests.openIntake(app)
            return page
        }
        let before = try app.browserWindowState(of: main)
        let opened = try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            let opened = try app.deliverLinks([
                E2ELink(address: LittleArcAreaTests.url("off").absoluteString, sender: true)
            ]
            )
            for link in opened { _ = try await link.page.waitForLoad(after: 0) }
            return opened
        }
        let littleArc = try app.littleArcWindows().count
        let after = try app.browserWindowState(of: main)
        let inWindow =
            opened.count == 1 && opened[0].inSpaceOnScreen && after.tabs.count == before.tabs.count + 1
            && after.shownTab != before.shownTab
        run.check(
            name, passed: littleArc == 0 && inWindow,
            "little_arc_windows=\(littleArc) opened_in_window=\(inWindow) tabs=\(before.tabs.count)->\(after.tabs.count)"
        )
    }
}

/// With no browser window open, a link from another app still opens Little Arc, its page in the profile of the Space
/// shown last; Open in Bow (Cmd+O) then opens a browser window on that Space with the same live page, not reloaded.
struct LittleArcNoWindowTest: E2ETest {
    let name = "little-arc.no_window"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        let main = try await LittleArcAreaTests.openWindow(app, run, seed: LittleArcAreaTests.homeAndWork)
        try await run.step("close the browser window", timeout: E2ETimeouts.step) {
            try await app.closeWindow(of: main)
        }
        let littleArc = try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            try app.deliverLinkToLittleArc(LittleArcAreaTests.url("nowindow"))
        }
        guard let littleArc else {
            return run.check(name, passed: false, "little_arc=none open_in_bow=not_tried")
        }
        let page = littleArc.page
        let loadID = try await run.step("load the page", timeout: E2ETimeouts.firstLoad) {
            _ = try await page.waitForLoad(after: 0)
            return try await page.string("window.bowLoadID")
        }
        let windows = try app.littleArcWindows()
        let opened = windows.count == 1 && !windows[0].intrudes && windows[0].showsPage && windows[0].openEnabled
        let moved = try await run.step("Open in Bow", timeout: E2ETimeouts.step) { () -> String in
            guard try app.pressKey("o", modifiers: .command, inLittleArc: littleArc) else {
                return "Cmd+O was not taken"
            }
            try await app.untilNoLittleArc()
            guard let shown = try app.browserWindow(showing: page) else { return "no window shows the page" }
            var problems: [String] = []
            if !shown.offScreen { problems.append("the new window is on screen or key") }
            if shown.state.spaceTitle != "Home" { problems.append("space=\(shown.state.spaceTitle)") }
            if shown.state.tabs.count != 2 { problems.append("Home lists \(shown.state.tabs.count) tabs") }
            if page.isClosed { problems.append("the page closed") }
            if try await page.string("window.bowLoadID") != loadID { problems.append("a new document") }
            let loads = try await page.string("sessionStorage.getItem('bowLoads')")
            if loads != "1" { problems.append("loads=\(loads)") }
            return problems.isEmpty ? "window" : problems.joined(separator: ", ")
        }
        run.check(
            name, passed: opened && moved == "window",
            "little_arc=\(opened ? "opened" : "\(windows)") open_in_bow=\(moved)")
    }
}

/// An alert from Little Arc's page comes up as a sheet on Little Arc, which stays off every screen with it, and is
/// answered once: the page goes on after one OK and no second sheet follows.
struct LittleArcDialogTest: E2ETest {
    let name = "little-arc.dialog"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        _ = try await LittleArcAreaTests.openWindow(app, run, seed: LittleArcAreaTests.homeAndWork)
        let littleArc = try await LittleArcAreaTests.deliver(app, run, LittleArcAreaTests.url("dialog"))
        let page = littleArc.page
        let shown = try await run.step("show an alert", timeout: E2ETimeouts.step) { () -> String in
            _ = try await page.evaluate("startAlert()")
            let dialog = try await E2EWaits.value(
                limit: 3, { try app.littleArcDialog(in: littleArc) }, until: { $0 != nil })
            guard let dialog else { return "none" }
            guard dialog.isAttached, dialog.title == "Little Arc alert" || dialog.message == "Little Arc alert" else {
                return "\(dialog)"
            }
            return try app.littleArcDialogIsOffScreen(in: littleArc) ? "sheet" : "on_screen"
        }
        let answered = try await run.step("answer the alert", timeout: E2ETimeouts.step) { () -> String in
            guard shown != "none" else { return "0" }
            try app.answerLittleArcDialog(in: littleArc, accept: true)
            try await E2EWaits.until(page, "window.alertsAnswered >= 1")
            var problems: [String] = []
            if try app.littleArcDialog(in: littleArc) != nil { problems.append("a second sheet") }
            let count = try await page.string("String(window.alertsAnswered)")
            if count != "1" { problems.append("answered=\(count)") }
            let state = try app.littleArcWindows()
            if state.count != 1 || state[0].intrudes { problems.append("Little Arc moved: \(state)") }
            return problems.isEmpty ? "1" : problems.joined(separator: ", ")
        }
        run.check(name, passed: shown == "sheet" && answered == "1", "dialog=\(shown) answered=\(answered)")
    }
}

/// A permission request from Little Arc's page shows the browser window's prompt, anchored to Little Arc's page and
/// off every screen, instead of being dismissed; allowing it grants the page the camera.
struct LittleArcPermissionTest: E2ETest {
    let name = "little-arc.permission"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        _ = try await LittleArcAreaTests.openWindow(app, run, seed: LittleArcAreaTests.homeAndWork)
        let littleArc = try await LittleArcAreaTests.deliver(app, run, E2EFixture.url("permissions/index.html"))
        let page = littleArc.page
        let prompt = try await run.step("ask for the camera", timeout: E2ETimeouts.step) { () -> String in
            _ = try await page.evaluate("startCamera()")
            // A dismissed request answers the page at once, which then reports the refusal.
            let shown = try await E2EWaits.value(
                limit: 3, { try app.littleArcPermissionPrompt(in: littleArc) }, until: { $0 != nil })
            guard let shown else { return "none (\(try await page.string("window.cameraResult")))" }
            if NSScreen.screens.contains(where: { $0.frame.intersects(shown.frame) }) { return "on_screen" }
            guard shown.kinds == ["camera"] else { return "kinds \(shown.kinds.sorted())" }
            try shown.answer(true)
            return "shown"
        }
        var result = "not_asked"
        if prompt == "shown" {
            result = try await run.step("allow", timeout: E2ETimeouts.step) {
                try await page.string("window.cameraResult")
            }
        }
        run.check(name, passed: prompt == "shown" && result == "granted", "prompt=\(prompt) allow=\(result)")
    }
}

/// While Little Arc is key, the main menu's page commands act on its page and never on the browser window behind it:
/// Reload Page (Cmd+R) reloads Little Arc's page only, Open Location (Cmd+L) focuses Little Arc's address showing the
/// page's address, and Find (Cmd+F) is disabled.
struct LittleArcMenuTest: E2ETest {
    let name = "little-arc.menu"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        let main = try await LittleArcAreaTests.openWindow(app, run, seed: LittleArcAreaTests.homeAndWork)
        let url = LittleArcAreaTests.url("menu")
        let littleArc = try await LittleArcAreaTests.deliver(app, run, url)
        let page = littleArc.page
        let mainID = try await main.string("window.bowLoadID")
        let pageID = try await page.string("window.bowLoadID")
        let reload = try await run.step("Cmd+R", timeout: E2ETimeouts.step) { () -> String in
            let handler = try app.chooseMenuItem(key: "r", modifiers: .command, inLittleArc: littleArc)
            guard handler == "LittleArcPanel" else { return "handled_by_\(handler)" }
            _ = try await page.waitForLoad(after: 1)
            return try await page.string("window.bowLoadID") != pageID ? "panel" : "no_reload"
        }
        let mainReloaded = try await main.string("window.bowLoadID") != mainID || main.finishedLoads != 1
        let address = try await run.step("Cmd+L", timeout: E2ETimeouts.step) { () -> String in
            let handler = try app.chooseMenuItem(key: "l", modifiers: .command, inLittleArc: littleArc)
            guard handler == "LittleArcPanel" else { return "handled_by_\(handler)" }
            let state = try app.littleArcAddress(in: littleArc)
            guard state.isEditing else { return "not_focused" }
            return state.text == url.absoluteString ? "focused" : "text=\(state.text)"
        }
        let find = try app.chooseMenuItem(key: "f", modifiers: .command, inLittleArc: littleArc)
        run.check(
            name, passed: reload == "panel" && !mainReloaded && address == "focused" && find == "disabled",
            "reload=\(reload) main_reloaded=\(mainReloaded) address=\(address) find=\(find)")
    }
}

/// Closing the last browser window while Little Arc is open keeps the app running (Little Arc counts as a window)
/// and leaves Little Arc and its page as they were.
struct LittleArcLastWindowTest: E2ETest {
    let name = "little-arc.last_window"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        let main = try await LittleArcAreaTests.openWindow(app, run, seed: LittleArcAreaTests.homeAndWork)
        let littleArc = try await LittleArcAreaTests.deliver(app, run, LittleArcAreaTests.url("last"))
        let page = littleArc.page
        let loadID = try await page.string("window.bowLoadID")
        try await run.step("close the browser window", timeout: E2ETimeouts.step) {
            try await app.closeWindow(of: main)
        }
        let decision = try app.lastWindowClosedDecision()
        let windows = try app.littleArcWindows()
        var problems: [String] = []
        if windows.count != 1 || !windows[0].showsPage || windows[0].intrudes { problems.append("\(windows)") }
        if page.isClosed { problems.append("the page closed") }
        if try await page.string("window.bowLoadID") != loadID { problems.append("a new document") }
        let kept = problems.isEmpty ? "kept" : problems.joined(separator: ", ")
        run.check(name, passed: decision == "stay" && kept == "kept", "app=\(decision) little_arc=\(kept)")
    }
}

/// Closing Little Arc after the last browser window closed leaves the app with no window, so the last window rule
/// runs again and decides to quit (or to wait for downloads, then quit). The e2e run reads the decision instead of
/// quitting; only app.quit quits.
struct LittleArcLastWindowThenCloseTest: E2ETest {
    let name = "little-arc.last_window_then_close"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        let main = try await LittleArcAreaTests.openWindow(app, run, seed: LittleArcAreaTests.homeAndWork)
        let littleArc = try await LittleArcAreaTests.deliver(app, run, LittleArcAreaTests.url("then_close"))
        _ = try app.takeLittleArcClosedDecision()
        // The run's downloads window, when an earlier test opened it, would keep the app open as any window does.
        let hidDownloads = try app.hideDownloadsWindow()
        defer { if hidDownloads { try? app.showDownloadsWindow() } }
        try await run.step("close the browser window", timeout: E2ETimeouts.step) {
            try await app.closeWindow(of: main)
        }
        // Little Arc is still open, so nothing has decided anything yet.
        let whileOpen = try app.takeLittleArcClosedDecision()
        try await run.step("close Little Arc", timeout: E2ETimeouts.step) {
            try app.closeLittleArc(littleArc)
            try await app.untilNoLittleArc()
        }
        let decision = try app.takeLittleArcClosedDecision()
        let rule = try app.lastWindowClosedDecision()
        run.check(
            name,
            passed: whileOpen == "none" && ["quit", "waitForDownloads"].contains(decision) && decision == rule,
            "while_open=\(whileOpen) on_close=\(decision) rule=\(rule)")
    }
}

/// A move whose adopt fails after the browser window switched Space switches the window back and keeps the page in
/// Little Arc as it was.
struct LittleArcAdoptFailTest: E2ETest {
    let name = "little-arc.adopt_fail"

    func run(_ run: E2ERun) async throws {
        let app = try LittleArcAreaTests.app(run)
        let main = try await LittleArcAreaTests.openWindow(app, run, seed: LittleArcAreaTests.homeAndWork)
        let littleArc = try await LittleArcAreaTests.deliver(app, run, LittleArcAreaTests.url("adopt"))
        let page = littleArc.page
        let loadID = try await page.string("window.bowLoadID")
        let before = try app.browserWindowState(of: main)
        try app.failNextLittleArcAdopt(in: littleArc)
        let taken = try app.pressKey("2", modifiers: .control, inLittleArc: littleArc)
        let after = try app.browserWindowState(of: main)
        let windows = try app.littleArcWindows()
        var problems: [String] = []
        if !taken { problems.append("Ctrl+2 was not taken") }
        if windows.count != 1 || !windows[0].showsPage { problems.append("Little Arc \(windows)") }
        if page.isClosed { problems.append("the page closed") }
        if try await page.string("window.bowLoadID") != loadID { problems.append("a new document") }
        let kept = problems.isEmpty ? "kept" : problems.joined(separator: ", ")
        run.check(
            name, passed: after.spaceTitle == "Home" && kept == "kept" && after == before,
            "space=\(after.spaceTitle) little_arc=\(kept) main_unchanged=\(after == before)")
    }
}
