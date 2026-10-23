import Foundation

/// Tests of the window chrome: Cmd+Shift+C copies the shown page's address and confirms. They write to a private
/// pasteboard the window is given, never the general one. Fixtures in E2E/Fixtures/chrome/.
@MainActor
enum ChromeTests {
    static let all: [any E2ETest] = [
        ChromeCopyTest(), ChromeCopyEdgesTest(), ChromeURLFieldTest(), ChromeToolbarHiddenTest(),
    ]

    typealias App = any E2EChromeApp & E2EMenuApp & E2EURLFieldApp & E2ECommandBarApp

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
                && !keyed.1.contains { $0.lowercased().hasSuffix("c") },
            "changed=\(keyed.0) string=\(board.string ?? "nil") page-keys=\(keyed.1)")

        let blank = try await run.step("copy on a blank tab", timeout: E2ETimeouts.firstLoad) {
            let blank = try await app.openWindow(at: URL(string: "about:blank")!)
            let blankBoard = try app.usePrivatePasteboard(of: blank)
            defer { blankBoard.release() }
            let before = blankBoard.changeCount
            var refused = false
            do {
                try ChromeTests.copyViaMenu(app, in: blank)
            } catch let error as E2EError where error.reason == nil && error.description.hasSuffix("is disabled") {
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

/// The sidebar's URL field shows the shown tab's site under the top row, follows tab switches and navigations (to a
/// blank page it shows the placeholder), and a click on it opens the command bar on the current address as Cmd+L does.
struct ChromeURLFieldTest: E2ETest {
    let name = "chrome.url-field"
    let tags = ["smoke"]
    let checks = ["chrome.url-field", "chrome.url-field.follows", "chrome.url-field.click"]

    func run(_ run: E2ERun) async throws {
        let app = try ChromeTests.app(run)
        let page = try await run.step("open the page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: ChromeTests.url("page"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }

        let shown = try await run.step("read the field", timeout: E2ETimeouts.step) {
            _ = try await ChromeTests.until { try app.urlField(of: page).text == "bow.test" }
            return try app.urlField(of: page)
        }
        // The sidebar is 264 wide with 14 and 12 points of padding: the field is 238 by 36.
        run.check(
            name,
            passed: shown.text == "bow.test" && !shown.isPlaceholder && shown.isShown && shown.isTopRowShown
                && shown.size == CGSize(width: 238, height: 36) && shown.isBelowTopRow,
            "field: \(shown)")

        let follows = try await run.step("switch tabs and navigate", timeout: E2ETimeouts.firstLoad) {
            let blank = try app.openTab(at: URL(string: "about:blank")!, besides: page, select: true)
            let onBlank = try await ChromeTests.until {
                let field = try app.urlField(of: blank)
                return field.isPlaceholder && field.text == "Search or type a URL"
            }
            try app.select(page)
            let back = try await ChromeTests.until { try app.urlField(of: page).text == "bow.test" }
            // A navigation the page makes itself, by script.
            _ = try await page.evaluate("location.href = 'about:blank'; true")
            let navigated = try await ChromeTests.until { try app.urlField(of: page).isPlaceholder }
            let loads = page.finishedLoads
            try page.load(ChromeTests.url("page"))
            _ = try await page.waitForLoad(after: loads)
            let reloaded = try await ChromeTests.until { try app.urlField(of: page).text == "bow.test" }
            return (onBlank, back, navigated, reloaded, try app.urlField(of: page))
        }
        run.check(
            "chrome.url-field.follows", passed: follows.0 && follows.1 && follows.2 && follows.3,
            "blank-tab=\(follows.0) back=\(follows.1) script-to-blank=\(follows.2) loaded-again=\(follows.3) "
                + "field: \(follows.4)")

        let clicked = try await run.step("click the field", timeout: E2ETimeouts.step) {
            try app.clickURLField(of: page)
            let bar = try app.commandBar(of: page)
            let opened = try await ChromeTests.until { bar.isShown && bar.hasKeyboard }
            let state = (opened, bar.text, bar.isTextSelected)
            try bar.press(.escape)
            let closed = try await ChromeTests.until { !bar.isShown }
            return (state, closed)
        }
        run.check(
            "chrome.url-field.click",
            passed: clicked.0.0 && clicked.0.1 == ChromeTests.url("page").absoluteString && clicked.0.2 && clicked.1,
            "opened=\(clicked.0.0) text=\(clicked.0.1) selected=\(clicked.0.2) closed-by-escape=\(clicked.1)")
    }
}

/// View > Hide Toolbar (Cmd+Shift+D) hides the top row and the URL field in every window, saves the choice (a window
/// opened afterwards starts hidden), keeps Cmd+L showing the address in the command bar, and Show Toolbar brings both
/// back.
struct ChromeToolbarHiddenTest: E2ETest {
    let name = "chrome.toolbar-hidden"
    let checks = ["chrome.toolbar-hidden", "chrome.toolbar-hidden.cmd-l", "chrome.toolbar-hidden.show"]

    func run(_ run: E2ERun) async throws {
        let app = try ChromeTests.app(run)
        let page = try await run.step("open the page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: ChromeTests.url("page"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let toggle = { try app.chooseMenuItem(key: "d", modifiers: [.command, .shift], in: page) }
        var hidden = false
        // A failed step must not leave the toolbar hidden for the tests after this one.
        defer { if hidden { try? toggle() } }

        let hide = try await run.step("hide the toolbar", timeout: E2ETimeouts.firstLoad) {
            let title = try app.toolbarMenuTitle(of: page)
            try toggle()
            hidden = true
            let gone = try await ChromeTests.until {
                let field = try app.urlField(of: page)
                return !field.isShown && !field.isTopRowShown
            }
            let other = try await app.openWindow(at: ChromeTests.url("keys"))
            let otherField = try app.urlField(of: other)
            try await app.closeWindow(of: other)
            return (title, gone, try app.toolbarMenuTitle(of: page), try app.savedShowsToolbar(), otherField)
        }
        run.check(
            name,
            passed: hide.0 == "Hide Toolbar" && hide.1 && hide.2 == "Show Toolbar" && hide.3 == false
                && !hide.4.isShown && !hide.4.isTopRowShown,
            "menu-before=\(hide.0) hidden=\(hide.1) menu-after=\(hide.2) saved=\(hide.3.map(String.init) ?? "nil") "
                + "new-window: \(hide.4)")

        let location = try await run.step("Cmd+L while hidden", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "l", modifiers: .command, in: page)
            let bar = try app.commandBar(of: page)
            let opened = try await ChromeTests.until { bar.isShown && bar.hasKeyboard }
            let text = bar.text
            try bar.press(.escape)
            _ = try await ChromeTests.until { !bar.isShown }
            return (opened, text)
        }
        run.check(
            "chrome.toolbar-hidden.cmd-l",
            passed: location.0 && location.1 == ChromeTests.url("page").absoluteString,
            "opened=\(location.0) text=\(location.1)")

        let show = try await run.step("show the toolbar", timeout: E2ETimeouts.step) {
            try toggle()
            hidden = false
            let back = try await ChromeTests.until {
                let field = try app.urlField(of: page)
                return field.isShown && field.isTopRowShown
            }
            return (back, try app.urlField(of: page), try app.toolbarMenuTitle(of: page), try app.savedShowsToolbar())
        }
        run.check(
            "chrome.toolbar-hidden.show",
            passed: show.0 && show.1.text == "bow.test" && show.1.isBelowTopRow
                && show.1.size == CGSize(width: 238, height: 36) && show.2 == "Hide Toolbar"
                && show.3 == true,
            "shown=\(show.0) field: \(show.1) menu=\(show.2) saved=\(show.3.map(String.init) ?? "nil")")
    }
}
