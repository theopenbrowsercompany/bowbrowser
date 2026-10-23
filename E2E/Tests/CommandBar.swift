import Foundation

/// Tests of the command bar. Fixtures in E2E/Fixtures/cmdbar/.
@MainActor
enum CommandBarTests {
    static let all: [any E2ETest] = [
        CommandBarTest(),
        CommandBarSpaceTest(),
        CommandBarHistoryTest(),
        CommandBarKeysTest(),
        CommandBarWindowsTest(),
    ]

    static func url(_ name: String) -> URL { E2EFixture.url("cmdbar/\(name).html") }

    typealias App = any E2ECommandBarApp & E2EMenuApp

    static func app(_ run: E2ERun) throws -> App {
        guard let app = run.app as? App else { throw E2EError("the app has no command bar") }
        return app
    }

    /// Opens the bar of `page`'s window with the menu shortcut Cmd+`key` and checks it shows with the keyboard in it.
    static func open(_ key: String, in page: any E2EPage, app: App) throws -> any E2ECommandBar {
        try app.chooseMenuItem(key: key, modifiers: .command, in: page)
        let bar = try app.commandBar(of: page)
        guard bar.isShown else { throw E2EError("the command bar did not show after Cmd+\(key.uppercased())") }
        guard bar.hasKeyboard else { throw E2EError("the keyboard is not in the command bar's field") }
        return bar
    }

    /// Whether `bar` meets `condition` within the step's time, checking every 10 ms.
    static func until(_ bar: any E2ECommandBar, _ condition: (any E2ECommandBar) -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(E2EWaits.budget(limit: 2))
        while !condition(bar) {
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    /// The window's tab summary once `done` accepts it, or as it reads shortly before the step's limit.
    static func summary(of page: any E2EPage, app: App, until done: (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while true {
            let summary = try app.tabSummary(of: page)
            if done(summary) || Date() >= deadline { return summary }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Cmd+T, typing, Escape, Enter in a new tab, Cmd+L and Enter in the current tab, arrow keys, blank text and a click
/// outside, in one window with tabs A and B.
struct CommandBarTest: E2ETest {
    let name = "cmdbar"
    let checks = [
        "cmdbar", "cmdbar.escape", "cmdbar.new-tab", "cmdbar.current-tab", "cmdbar.blank", "cmdbar.arrows",
        "cmdbar.click-outside",
    ]

    func run(_ run: E2ERun) async throws {
        let app = try CommandBarTests.app(run)
        let a = try await run.step("open A and B", timeout: E2ETimeouts.firstLoad) {
            let a = try await app.openWindow(at: CommandBarTests.url("a"))
            _ = try await a.waitForLoad(after: 0)
            let b = try app.openTab(at: CommandBarTests.url("b"), besides: a, select: false)
            _ = try await b.waitForLoad(after: 0)
            return a
        }
        let start = try await run.step("read the tabs", timeout: E2ETimeouts.step) {
            try await CommandBarTests.summary(of: a, app: app) { $0.hasSuffix("today=[A,B] active=A") }
        }

        let query = try await run.step("Cmd+T and type a", timeout: E2ETimeouts.step) {
            let bar = try CommandBarTests.open("t", in: a, app: app)
            guard bar.text.isEmpty else { throw E2EError("the bar opened with \"\(bar.text)\"") }
            let empty = try await bar.waitForResults()
            try bar.type("a")
            return (empty, try await bar.waitForResults())
        }
        run.check(
            name, passed: query.1.first?.description == "tab:A" && query.0.allSatisfy { $0.kind == "tab" },
            "query=a first=\(query.1.first?.description ?? "none") rows=\(query.1.map(\.description)) "
                + "empty=\(query.0.map(\.description))")

        let escaped = try await run.step("Escape", timeout: E2ETimeouts.step) {
            let bar = try app.commandBar(of: a)
            try bar.press(.escape)
            return (bar.isShown, try app.tabSummary(of: a))
        }
        run.check(
            "cmdbar.escape", passed: !escaped.0 && escaped.1 == start,
            "shown=\(escaped.0) \(escaped.1)")

        let c = CommandBarTests.url("c").absoluteString
        let newTab = try await run.step("Cmd+T, type an address, Enter", timeout: E2ETimeouts.firstLoad) {
            let bar = try CommandBarTests.open("t", in: a, app: app)
            try bar.type("bow.test/cmdbar/c.html")
            let first = try await bar.waitForResults().first?.description ?? "none"
            try bar.press(.enter)
            let summary = try await CommandBarTests.summary(of: a, app: app) { $0.hasSuffix("today=[A,C,B] active=C") }
            return (first, bar.isShown, summary)
        }
        run.check(
            "cmdbar.new-tab",
            passed: newTab.0 == "navigate:\(c)" && !newTab.1 && newTab.2.hasSuffix("today=[A,C,B] active=C"),
            "first=\(newTab.0) shown=\(newTab.1) \(newTab.2)")

        let current = try await run.step("Cmd+L, type an address, Enter", timeout: E2ETimeouts.firstLoad) {
            let bar = try CommandBarTests.open("l", in: a, app: app)
            let opened = (bar.text, bar.isTextSelected)
            try bar.type("bow.test/cmdbar/d.html")
            let typed = bar.text
            _ = try await bar.waitForResults()
            try bar.press(.enter)
            let summary = try await CommandBarTests.summary(of: a, app: app) { $0.hasSuffix("today=[A,D,B] active=D") }
            return (opened, typed, summary)
        }
        run.check(
            "cmdbar.current-tab",
            passed: current.0.0 == c && current.0.1 && current.1 == "bow.test/cmdbar/d.html"
                && current.2.hasSuffix("today=[A,D,B] active=D"),
            "text=\(current.0.0) selected=\(current.0.1) typed=\(current.1) \(current.2)")

        let blank = try await run.step("Cmd+T, blank text, Enter", timeout: E2ETimeouts.step) {
            let bar = try CommandBarTests.open("t", in: a, app: app)
            try bar.type("   ")
            let rows = try await bar.waitForResults()
            try bar.press(.enter)
            let result = (rows, bar.selectedRow, bar.isShown, try app.tabSummary(of: a))
            try bar.press(.escape)
            return result
        }
        run.check(
            "cmdbar.blank",
            passed: blank.1 == nil && blank.2 && blank.3.hasSuffix("today=[A,D,B] active=D")
                && blank.0.allSatisfy { $0.kind == "tab" },
            "selected=\(blank.1.map(String.init) ?? "none") shown-after-enter=\(blank.2) "
                + "rows=\(blank.0.map(\.description)) \(blank.3)")

        // With nothing typed the open tabs show most recently used first: D (shown), A, then B (never shown).
        let arrows = try await run.step("Cmd+T, arrow keys, Enter", timeout: E2ETimeouts.step) {
            let bar = try CommandBarTests.open("t", in: a, app: app)
            let rows = try await bar.waitForResults()
            var moves: [Int] = []
            for key in [E2ECommandBarKey.down, .down, .down, .up] {
                try bar.press(key)
                moves.append(bar.selectedRow ?? -1)
            }
            try bar.press(.enter)
            let summary = try await CommandBarTests.summary(of: a, app: app) { $0.hasSuffix("active=A") }
            return (rows, moves, summary)
        }
        run.check(
            "cmdbar.arrows",
            passed: arrows.0.map(\.description) == ["tab:D", "tab:A", "tab:B"] && arrows.1 == [0, 1, 2, 1]
                && arrows.2.hasSuffix("today=[A,D,B] active=A"),
            "rows=\(arrows.0.map(\.description)) moves=\(arrows.1.map(String.init).joined(separator: ",")) \(arrows.2)")

        let outside = try await run.step("click outside", timeout: E2ETimeouts.step) {
            let bar = try CommandBarTests.open("t", in: a, app: app)
            try bar.type("b")
            _ = try await bar.waitForResults()
            try bar.clickOutside()
            return (bar.isShown, try app.tabSummary(of: a))
        }
        run.check(
            "cmdbar.click-outside", passed: !outside.0 && outside.1.hasSuffix("today=[A,D,B] active=A"),
            "shown=\(outside.0) \(outside.1)")
    }
}

/// Spaces "work" (tab A) and "personal" (tab Beta, its own profile) with work on screen: typing beta lists Beta with
/// its Space, and Enter brings personal on screen with Beta selected, adding no tab. (A single letter such as b would
/// also match every fixture's address, bow.test.)
struct CommandBarSpaceTest: E2ETest {
    let name = "cmdbar.space"

    func run(_ run: E2ERun) async throws {
        let app = try CommandBarTests.app(run)
        guard let seeder = run.app as? any E2EStoreSeedApp else { throw E2EError("the app cannot seed a sidebar") }
        let personal = try seeder.testProfileID() + "-personal"
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace("work", today: [.tab("A", url: CommandBarTests.url("a"))]),
                E2ESeedSpace(
                    "personal", profile: .new(E2EProfile(id: personal, isPersistent: false)),
                    today: [.tab("Beta", url: CommandBarTests.url("beta"))]),
            ],
            activeSpace: "work")
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await seeder.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let chosen = try await run.step("Cmd+T, type beta, Enter", timeout: E2ETimeouts.firstLoad) {
            let bar = try CommandBarTests.open("t", in: page, app: app)
            try bar.type("beta")
            let first = try await bar.waitForResults().first
            try bar.press(.enter)
            let summary = try await CommandBarTests.summary(of: page, app: app) {
                $0 == "space=personal today=[Beta] active=Beta"
            }
            return (first, summary)
        }
        run.check(
            name,
            passed: chosen.0?.description == "tab:Beta" && chosen.0?.space == "personal"
                && chosen.1 == "space=personal today=[Beta] active=Beta",
            "first=\(chosen.0?.description ?? "none") space=\(chosen.0?.space ?? "none") then \(chosen.1)")
    }
}

/// A page visited and then left shows as a history row from the tab's profile, and Enter opens it in a new tab.
struct CommandBarHistoryTest: E2ETest {
    let name = "cmdbar.history"

    func run(_ run: E2ERun) async throws {
        let app = try CommandBarTests.app(run)
        let page = try await run.step("visit a page and leave it", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: CommandBarTests.url("visited"))
            _ = try await page.waitForLoad(after: 0)
            try page.load(CommandBarTests.url("a"))
            _ = try await page.waitForLoad(after: 1)
            return page
        }
        let visited = CommandBarTests.url("visited")
        let chosen = try await run.step("Cmd+T, type visit, Enter", timeout: E2ETimeouts.firstLoad) {
            let bar = try CommandBarTests.open("t", in: page, app: app)
            try bar.type("visit")
            let first = try await bar.waitForResults().first
            try bar.press(.enter)
            let summary = try await CommandBarTests.summary(of: page, app: app) {
                $0.hasSuffix("today=[A,Visited page] active=Visited page")
            }
            return (first, summary)
        }
        run.check(
            name,
            passed: chosen.0?.kind == "history" && chosen.0?.url == visited
                && chosen.1.hasSuffix("today=[A,Visited page] active=Visited page"),
            "first=\(chosen.0?.description ?? "none") url=\(chosen.0?.url.lastPathComponent ?? "none") then \(chosen.1)"
        )
    }
}

/// A page that listens for keys, focused through page input, is sent Cmd+T, Escape and Cmd+L through DevTools: the
/// app claims each one (the bar opens, closes, opens on the page's address) and the page sees none of them, while a
/// plain J after them still reaches it.
struct CommandBarKeysTest: E2ETest {
    let name = "cmdbar.keys"

    func run(_ run: E2ERun) async throws {
        let app = try CommandBarTests.app(run)
        let page = try await run.step("open the keys page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: CommandBarTests.url("keys"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let keyDowns = { try await page.evaluate("window.keyDowns") as? [String] ?? [] }
        // A page may drop the first keys after its focus changes, so J is pressed until the page has seen one.
        try await run.step("focus the page", timeout: E2ETimeouts.step) {
            try await page.click("#field")
            let deadline = Date().addingTimeInterval(E2EWaits.budget())
            while !(try await keyDowns().contains("j")) {
                guard Date() < deadline else { throw E2EError("the page saw no J key: \(try await keyDowns())") }
                try await page.press(letter: "j", macKeyCode: 38, modifiers: [])
            }
        }
        let bar = try app.commandBar(of: page)
        let seen = try await run.step("send Cmd+T, Escape and Cmd+L to the page", timeout: E2ETimeouts.step) {
            let before = try await keyDowns().count
            // The tab hands each key to the app on its way back from the page's process, so wait for the bar.
            try await page.press(letter: "t", macKeyCode: 17, modifiers: .command)
            let afterT = try await CommandBarTests.until(bar) { $0.isShown }
            try await page.press(.escape)
            let afterEscape = try await CommandBarTests.until(bar) { !$0.isShown }
            try await page.press(letter: "l", macKeyCode: 37, modifiers: .command)
            let afterL = (try await CommandBarTests.until(bar) { $0.isShown && $0.hasKeyboard }, bar.text)
            if afterL.0 { try bar.press(.escape) }
            try await page.press(letter: "j", macKeyCode: 38, modifiers: [])
            try await E2EWaits.until(page, "window.keyDowns.length > \(before)")
            return (afterT, afterEscape, afterL, Array(try await keyDowns().dropFirst(before)))
        }
        let url = CommandBarTests.url("keys").absoluteString
        run.check(
            name,
            passed: seen.0 && seen.1 && seen.2.0 && seen.2.1 == url && seen.3 == ["j"],
            "cmd-t=\(seen.0 ? "shown" : "hidden") escape=\(seen.1 ? "closed" : "shown") "
                + "cmd-l=\(seen.2.0 ? seen.2.1 : "hidden") page-keys=[\(seen.3.joined(separator: ","))]")
    }
}

/// Two windows each with a bar: each opens over its own window, typing in one leaves the other as it is, and Escape
/// closes only its own.
struct CommandBarWindowsTest: E2ETest {
    let name = "cmdbar.windows"

    func run(_ run: E2ERun) async throws {
        let app = try CommandBarTests.app(run)
        let pages = try await run.step("open two windows", timeout: E2ETimeouts.firstLoad) {
            let one = try await app.openWindow(at: CommandBarTests.url("a"))
            _ = try await one.waitForLoad(after: 0)
            let two = try await app.openWindow(at: CommandBarTests.url("b"))
            _ = try await two.waitForLoad(after: 0)
            return (one, two)
        }
        let result = try await run.step("a bar in each window", timeout: E2ETimeouts.step) {
            let one = try CommandBarTests.open("l", in: pages.0, app: app)
            let two = try CommandBarTests.open("l", in: pages.1, app: app)
            try two.type("b")
            _ = try await two.waitForResults()
            let texts = (one.text, two.text)
            try two.press(.escape)
            let shown = (one.isShown, two.isShown)
            try one.press(.escape)
            return (texts, shown)
        }
        let a = CommandBarTests.url("a").absoluteString
        run.check(
            name, passed: result.0.0 == a && result.0.1 == "b" && result.1.0 && !result.1.1,
            "one=\(result.0.0) two=\(result.0.1) after-escape-in-two: one=\(result.1.0) two=\(result.1.1)")
    }
}
