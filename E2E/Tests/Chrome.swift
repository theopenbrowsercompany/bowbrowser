import Foundation

/// Tests of the window chrome: Cmd+Shift+C copies the shown page's address and confirms. They write to a private
/// pasteboard the window is given, never the general one. Fixtures in E2E/Fixtures/chrome/.
@MainActor
enum ChromeTests {
    static let all: [any E2ETest] = [ChromeCopyTest(), ChromeCopyEdgesTest()]

    typealias App = any E2EChromeApp & E2EMenuApp

    static func app(_ run: E2ERun) throws -> App {
        guard let app = run.app as? App else { throw E2EError("the app has no chrome hooks") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("chrome/\(name).html") }

    /// Waits until `condition` holds, or the step's wait budget runs out, and returns whether it held.
    static func until(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try condition()
    }

    static func copyViaMenu(_ app: App, in page: any E2EPage) throws {
        try app.chooseMenuItem(key: "c", modifiers: [.command, .shift], in: page)
    }
}

/// Cmd+Shift+C through the menu copies the address as a URL and as a string, shows one confirmation that a second
/// press restarts, and the confirmation fades by itself.
struct ChromeCopyTest: E2ETest {
    let name = "chrome.copy"
    let tags = ["smoke"]
    let checks = ["chrome.copy", "chrome.copy.twice", "chrome.copy.fade"]

    func run(_ run: E2ERun) async throws {
        let app = try ChromeTests.app(run)
        let page = try await run.step("open the page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: ChromeTests.url("page"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let board = try app.usePrivatePasteboard(of: page)
        defer { board.release() }
        let address = ChromeTests.url("page")

        let copied = try await run.step("Cmd+Shift+C", timeout: E2ETimeouts.step) {
            let before = board.changeCount
            try ChromeTests.copyViaMenu(app, in: page)
            let changed = try await ChromeTests.until { board.changeCount != before }
            let shown = try await ChromeTests.until { try app.confirmation(of: page).isShown }
            return (changed, shown, try app.confirmation(of: page))
        }
        run.check(
            name,
            passed: copied.0 && copied.1 && board.string == address.absoluteString && board.url == address
                && copied.2.text == "Copied URL",
            "changed=\(copied.0) string=\(board.string ?? "nil") url=\(board.url?.absoluteString ?? "nil") "
                + "confirmation=\(copied.2)")

        let twice = try await run.step("press again", timeout: E2ETimeouts.step) {
            let before = board.changeCount
            try ChromeTests.copyViaMenu(app, in: page)
            try ChromeTests.copyViaMenu(app, in: page)
            _ = try await ChromeTests.until { board.changeCount >= before + 2 }
            return try app.confirmation(of: page)
        }
        run.check(
            "chrome.copy.twice", passed: twice.isShown && twice.viewCount == 1,
            "confirmation=\(twice)")

        let faded = try await run.step("wait for the fade", timeout: E2ETimeouts.step) {
            try await ChromeTests.until { !(try app.confirmation(of: page).isShown) }
        }
        run.check("chrome.copy.fade", passed: faded, "the confirmation never faded")
    }
}

/// A page that handles Cmd+Shift+C itself still has it taken by the app, a blank tab copies nothing and shows
/// nothing, and a window that closes while the confirmation shows closes cleanly.
struct ChromeCopyEdgesTest: E2ETest {
    let name = "chrome.copy.edges"
    let checks = ["chrome.copy.page-key", "chrome.copy.blank", "chrome.copy.window-close"]

    func run(_ run: E2ERun) async throws {
        let app = try ChromeTests.app(run)
        let page = try await run.step("open the keys page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: ChromeTests.url("keys"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let board = try app.usePrivatePasteboard(of: page)
        defer { board.release() }
        let keyDowns = { try await page.evaluate("window.keyDowns") as? [String] ?? [] }

        let keyed = try await run.step("send Cmd+Shift+C to the page", timeout: E2ETimeouts.step) {
            try await page.click("#field")
            let before = board.changeCount
            try await page.press(letter: "c", macKeyCode: 8, modifiers: [.command, .shift])
            let changed = try await ChromeTests.until { board.changeCount != before }
            try await page.press(letter: "j", macKeyCode: 38, modifiers: [])
            try await E2EWaits.until(page, "window.keyDowns.some(k => k === 'j')")
            return (changed, try await keyDowns())
        }
        run.check(
            "chrome.copy.page-key",
            passed: keyed.0 && board.string == ChromeTests.url("keys").absoluteString
                && !keyed.1.contains { $0.contains("c") },
            "changed=\(keyed.0) string=\(board.string ?? "nil") page-keys=\(keyed.1)")

        let blank = try await run.step("copy on a blank tab", timeout: E2ETimeouts.firstLoad) {
            let blank = try await app.openWindow(at: URL(string: "about:blank")!)
            let blankBoard = try app.usePrivatePasteboard(of: blank)
            defer { blankBoard.release() }
            let before = blankBoard.changeCount
            var refused = false
            do {
                try ChromeTests.copyViaMenu(app, in: blank)
            } catch let error as E2EError where error.reason == nil {
                refused = true
            }
            let confirmation = try app.confirmation(of: blank)
            return (refused, blankBoard.changeCount == before, confirmation.isShown)
        }
        run.check(
            "chrome.copy.blank", passed: blank.0 && blank.1 && !blank.2,
            "menu-refused=\(blank.0) pasteboard-unchanged=\(blank.1) confirmation-shown=\(blank.2)")

        let closed = try await run.step("close the window while it shows", timeout: E2ETimeouts.step) {
            try ChromeTests.copyViaMenu(app, in: page)
            let shown = try await ChromeTests.until { try app.confirmation(of: page).isShown }
            try await app.closeWindow(of: page)
            return shown
        }
        run.check("chrome.copy.window-close", passed: closed, "the confirmation never showed before the close")
    }
}
