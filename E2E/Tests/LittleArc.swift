import Foundation

/// Little Arc: a link from another app opens in a small floating window instead of the browser window, its page moves
/// into a chosen Space with one key and keeps running, and closing Little Arc closes its page. With the setting off,
/// links open in the browser window as before. Fixtures in E2E/Fixtures/littlearc/.
@MainActor
enum LittleArcTests {
    static let all: [any E2ETest] = [LittleArcPromoteTest(), LittleArcCloseTest(), LittleArcOffTest()]

    static func url(_ name: String) -> URL { E2EFixture.url("littlearc/page.html?name=\(name)") }

    static func app(_ run: E2ERun) throws -> any E2ELittleArcApp & E2EStoreSeedApp & E2ELinksApp {
        guard let app = run.app as? any E2ELittleArcApp & E2EStoreSeedApp & E2ELinksApp else {
            throw E2EError("the app has no Little Arc")
        }
        return app
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
        let app = try LittleArcTests.app(run)
        try app.setLittleArcSetting(nil)
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace("Home", today: [.tab("home", url: LittleArcTests.url("home"))]),
                E2ESeedSpace("Work", today: [.tab("work", url: LittleArcTests.url("work"))]),
            ],
            activeSpace: "Home")
        let main = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let before = try app.browserWindowState(of: main)

        let littleArc = try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            guard let window = try app.deliverLinkToLittleArc(LittleArcTests.url("link")) else {
                throw E2EError("the link opened no Little Arc window")
            }
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let windows = try app.littleArcWindows()
        let windowResult: String
        if windows.count != 1 {
            windowResult = "\(windows.count)_windows"
        } else if let problem = LittleArcTests.problems(of: windows[0], spaces: ["Home", "Work"]) {
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
        let app = try LittleArcTests.app(run)
        try app.setLittleArcSetting(true)
        let main = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: LittleArcTests.url("main"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let before = try app.browserWindowState(of: main)
        let browsersBefore = app.openBrowsers

        let littleArc = try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            guard let window = try app.deliverLinkToLittleArc(LittleArcTests.url("draft")) else {
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
        let app = try LittleArcTests.app(run)
        try app.setLittleArcSetting(false)
        let main = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: LittleArcTests.url("main"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let before = try app.browserWindowState(of: main)
        let opened = try await run.step("deliver a link", timeout: E2ETimeouts.firstLoad) {
            let opened = try app.deliverLinks([E2ELink(address: LittleArcTests.url("off").absoluteString, sender: true)])
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
            "little_arc_windows=\(littleArc) opened_in_window=\(inWindow) tabs=\(before.tabs.count)->\(after.tabs.count)")
    }
}
