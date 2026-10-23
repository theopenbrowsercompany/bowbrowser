import Foundation

/// Tests of a page's alert, confirm and prompt: each comes up as a sheet on the window showing its tab, titled with
/// the page's origin, and the page gets the answer pressed on the sheet; a tab the window does not show has its alert
/// answered at once and shown when the tab is, and its confirm and prompt cancelled; switching away, navigating,
/// closing the tab or the window take the sheet down; a popup window's dialog never blocks the app. No dialog is ever
/// an app modal panel. Fixtures in E2E/Fixtures/dialogs/: page.html asks through `bowAsk(kind, message, value)` and
/// records what it got back in `bowResults`; popup.html, opened as a sized popup window, asks as it loads.
@MainActor
enum PageDialogsTests {
    static let all: [any E2ETest] = [
        PageDialogsAlertTest(),
        PageDialogsConfirmTest(),
        PageDialogsPromptTest(),
        PageDialogsBackgroundTest(),
        PageDialogsSwitchTest(),
        PageDialogsCloseTest(),
        PageDialogsPopupTest(),
    ]

    static func url(_ name: String) -> URL { E2EFixture.url("dialogs/page.html?name=\(name)") }

    static func dialogsApp(_ run: E2ERun) throws -> any E2EPageDialogsApp {
        guard let app = run.app as? any E2EPageDialogsApp else { throw E2EError("the app has no page dialogs") }
        return app
    }

    /// Opens a window on the fixture named `name` and waits for it to load.
    static func openWindow(_ run: E2ERun, _ name: String = "A") async throws -> any E2EPage {
        try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: url(name))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
    }

    /// Opens the fixture named `name` in a tab of `page`'s window, in the background unless `select`.
    static func openTab(_ run: E2ERun, _ name: String, besides page: any E2EPage, select: Bool = false) async throws
        -> any E2EPage
    {
        try await run.step("open tab \(name)", timeout: E2ETimeouts.firstLoad) {
            let tab = try run.app.openTab(at: url(name), besides: page, select: select)
            _ = try await tab.waitForLoad(after: 0)
            return tab
        }
    }

    /// Has `page` ask for a dialog outside the script that asks, so this call returns while the dialog is up.
    static func ask(_ page: any E2EPage, _ kind: String, _ message: String, _ value: String = "") async throws {
        _ = try await page.evaluate("bowAsk('\(kind)', '\(message)', '\(value)'); true")
    }

    /// Waits for a dialog sheet on `page`'s window.
    static func untilDialog(_ app: any E2EPageDialogsApp, besides page: any E2EPage) async throws -> E2EPageDialog {
        var dialog: E2EPageDialog?
        guard
            try await TabEdgesTests.until({
                dialog = try app.pageDialog(besides: page)
                return dialog != nil
            }), let dialog
        else { throw E2EError("no dialog came up") }
        return dialog
    }

    /// Waits until `page` has recorded `count` answers, and returns them joined by commas.
    static func results(_ page: any E2EPage, count: Int) async throws -> String {
        _ = try await E2EWaits.until(page, "window.bowResults.length >= \(count)")
        return try await page.string("window.bowResults.join(',')")
    }

    static func describe(_ dialog: E2EPageDialog?) -> String { dialog.map(\.description) ?? "none" }
}

/// An alert from the shown tab comes up as a sheet on its window, titled with the page's origin, with only OK, and
/// the page goes on once OK is pressed.
struct PageDialogsAlertTest: E2ETest {
    let name = "dialogs.alert"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        let (dialog, modal) = try await run.step("show an alert", timeout: E2ETimeouts.step) {
            try await PageDialogsTests.ask(page, "alert", "Hello from the page")
            return (try await PageDialogsTests.untilDialog(app, besides: page), app.appModalPanelShown)
        }
        let (results, after) = try await run.step("press OK", timeout: E2ETimeouts.step) {
            try app.answerPageDialog(besides: page, accept: true, text: nil)
            return (try await PageDialogsTests.results(page, count: 1), try app.pageDialog(besides: page))
        }
        let expected = E2EPageDialog(
            title: "bow.test says", message: "Hello from the page", buttons: ["OK"], field: nil, isAttached: true)
        run.check(
            name, passed: dialog == expected && !modal && results == "alert:undefined" && after == nil,
            "\(dialog) app-modal=\(modal) page=\(results) after=\(PageDialogsTests.describe(after))")
    }
}

/// A confirm from the shown tab has OK and Cancel, and the page gets true for OK and false for Cancel.
struct PageDialogsConfirmTest: E2ETest {
    let name = "dialogs.confirm"

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        var dialogs: [E2EPageDialog] = []
        for (index, accept) in [true, false].enumerated() {
            try await run.step("answer a confirm with \(accept ? "OK" : "Cancel")", timeout: E2ETimeouts.step) {
                try await PageDialogsTests.ask(page, "confirm", "Go on?")
                dialogs.append(try await PageDialogsTests.untilDialog(app, besides: page))
                try app.answerPageDialog(besides: page, accept: accept, text: nil)
                _ = try await PageDialogsTests.results(page, count: index + 1)
            }
        }
        let results = try await PageDialogsTests.results(page, count: 2)
        let expected = E2EPageDialog(
            title: "bow.test says", message: "Go on?", buttons: ["OK", "Cancel"], field: nil, isAttached: true)
        run.check(
            name, passed: dialogs == [expected, expected] && results == "confirm:true,confirm:false",
            "\(PageDialogsTests.describe(dialogs.first)) page=\(results)")
    }
}

/// A prompt from the shown tab has a text field holding the page's default text, OK and Cancel; the page gets the
/// typed text for OK and null for Cancel.
struct PageDialogsPromptTest: E2ETest {
    let name = "dialogs.prompt"

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        var dialogs: [E2EPageDialog] = []
        for (index, (accept, text)) in [(true, "typed"), (false, "ignored")].enumerated() {
            try await run.step("answer a prompt with \(accept ? "OK" : "Cancel")", timeout: E2ETimeouts.step) {
                try await PageDialogsTests.ask(page, "prompt", "Your name?", "seed")
                dialogs.append(try await PageDialogsTests.untilDialog(app, besides: page))
                try app.answerPageDialog(besides: page, accept: accept, text: text)
                _ = try await PageDialogsTests.results(page, count: index + 1)
            }
        }
        let results = try await PageDialogsTests.results(page, count: 2)
        let expected = E2EPageDialog(
            title: "bow.test says", message: "Your name?", buttons: ["OK", "Cancel"], field: "seed", isAttached: true)
        run.check(
            name, passed: dialogs == [expected, expected] && results == "prompt:typed,prompt:null",
            "\(PageDialogsTests.describe(dialogs.first)) page=\(results)")
    }
}

/// A background tab's alert is answered at once and shows no sheet until its tab is shown, then comes up there; a
/// background tab's confirm and prompt are cancelled at once and never come up.
struct PageDialogsBackgroundTest: E2ETest {
    let name = "dialogs.background"
    let checks = ["dialogs.background_alert", "dialogs.background_confirm"]

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        let other = try await PageDialogsTests.openTab(run, "B", besides: page)
        let (returned, upWhileHidden, waits) = try await run.step(
            "alert from the background", timeout: E2ETimeouts.step
        ) {
            try await PageDialogsTests.ask(other, "alert", "While you were away")
            let returned = try await PageDialogsTests.results(other, count: 1)
            return (returned, try app.pageDialog(besides: page), try app.pageDialogWaits(for: other))
        }
        let (shown, after) = try await run.step("show the tab", timeout: E2ETimeouts.step) {
            try run.app.select(other)
            let shown = try await PageDialogsTests.untilDialog(app, besides: page)
            try app.answerPageDialog(besides: page, accept: true, text: nil)
            return (shown, try app.pageDialogWaits(for: other))
        }
        run.check(
            "dialogs.background_alert",
            passed: returned == "alert:undefined" && upWhileHidden == nil && waits
                && shown.message
                    == "While you were away"
                && shown.isAttached && !after,
            "page=\(returned) hidden-sheet=\(PageDialogsTests.describe(upWhileHidden)) waits=\(waits)"
                + " shown=\(shown) after-answer-waits=\(after)")
        let (results, up, waitsAfter, upOnShow) = try await run.step(
            "confirm and prompt from the background", timeout: E2ETimeouts.step
        ) {
            try run.app.select(page)
            try await PageDialogsTests.ask(other, "confirm", "Hidden confirm")
            _ = try await PageDialogsTests.results(other, count: 2)
            try await PageDialogsTests.ask(other, "prompt", "Hidden prompt", "seed")
            let results = try await PageDialogsTests.results(other, count: 3)
            let up = try app.pageDialog(besides: page)
            let waits = try app.pageDialogWaits(for: other)
            try run.app.select(other)
            return (results, up, waits, try app.pageDialog(besides: page))
        }
        run.check(
            "dialogs.background_confirm",
            passed: results == "alert:undefined,confirm:false,prompt:null" && up == nil && !waitsAfter
                && upOnShow == nil,
            "page=\(results) sheet=\(PageDialogsTests.describe(up)) waits=\(waitsAfter)"
                + " on-show=\(PageDialogsTests.describe(upOnShow))")
    }
}

/// Switching away from a tab whose dialog is up takes the sheet down: a confirm is cancelled, and an alert is
/// answered and comes up again when its tab is shown again.
struct PageDialogsSwitchTest: E2ETest {
    let name = "dialogs.switch_away"

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        let other = try await PageDialogsTests.openTab(run, "B", besides: page)
        let (confirmResult, confirmAfter) = try await run.step("switch away from a confirm", timeout: E2ETimeouts.step)
        {
            try await PageDialogsTests.ask(page, "confirm", "Stay?")
            _ = try await PageDialogsTests.untilDialog(app, besides: page)
            try run.app.select(other)
            return (try await PageDialogsTests.results(page, count: 1), try app.pageDialog(besides: page))
        }
        let (alertResult, alertAfter, back) = try await run.step(
            "switch away from an alert and back", timeout: E2ETimeouts.step
        ) {
            try run.app.select(page)
            try await PageDialogsTests.ask(page, "alert", "Still here")
            _ = try await PageDialogsTests.untilDialog(app, besides: page)
            try run.app.select(other)
            let result = try await PageDialogsTests.results(page, count: 2)
            let after = try app.pageDialog(besides: page)
            try run.app.select(page)
            let back = try await PageDialogsTests.untilDialog(app, besides: page)
            try app.answerPageDialog(besides: page, accept: true, text: nil)
            return (result, after, back)
        }
        run.check(
            name,
            passed: confirmResult == "confirm:false" && confirmAfter == nil
                && alertResult == "confirm:false,alert:undefined" && alertAfter == nil && back.message == "Still here",
            "confirm=\(confirmResult) sheet=\(PageDialogsTests.describe(confirmAfter)) alert=\(alertResult)"
                + " sheet=\(PageDialogsTests.describe(alertAfter)) back=\(back)")
    }
}

/// A navigation, closing the tab and closing the window each take a dialog down and answer it, and none of them
/// waits on the page.
struct PageDialogsCloseTest: E2ETest {
    let name = "dialogs.close"
    let checks = ["dialogs.navigate", "dialogs.close_tab", "dialogs.close_window"]

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        let (navigated, afterNavigation) = try await run.step(
            "navigate with a confirm up", timeout: E2ETimeouts.firstLoad
        ) {
            try await PageDialogsTests.ask(page, "confirm", "Leave?")
            _ = try await PageDialogsTests.untilDialog(app, besides: page)
            let loads = page.finishedLoads
            try page.load(PageDialogsTests.url("navigated"))
            _ = try await page.waitForLoad(after: loads)
            return (try await page.string("document.title"), try app.pageDialog(besides: page))
        }
        run.check(
            "dialogs.navigate", passed: navigated == "Dialogs navigated" && afterNavigation == nil,
            "title=\(navigated) sheet=\(PageDialogsTests.describe(afterNavigation))")
        let other = try await PageDialogsTests.openTab(run, "C", besides: page, select: true)
        let (closed, afterClose) = try await run.step("close the tab with a prompt up", timeout: E2ETimeouts.step) {
            try await PageDialogsTests.ask(other, "prompt", "Closing?")
            _ = try await PageDialogsTests.untilDialog(app, besides: page)
            let closed = try await run.app.closeTab(other)
            return (closed, try app.pageDialog(besides: page))
        }
        run.check(
            "dialogs.close_tab", passed: closed && afterClose == nil,
            "closed=\(closed) sheet=\(PageDialogsTests.describe(afterClose))")
        let second = try await PageDialogsTests.openWindow(run, "W")
        let modal = try await run.step("close the window with an alert up", timeout: E2ETimeouts.step) {
            try await PageDialogsTests.ask(second, "alert", "Window closing")
            _ = try await PageDialogsTests.untilDialog(app, besides: second)
            try await run.app.closeWindow(of: second)
            return app.appModalPanelShown
        }
        run.check(
            "dialogs.close_window", passed: second.isClosed && !modal,
            "closed=\(second.isClosed) app-modal=\(modal)")
    }
}

/// A popup window of the engine's own (a sized `window.open`) asking for an alert and a confirm never blocks the
/// app: an e2e run parks popups in no window, so both are answered at once as cancelled, and no app modal panel
/// shows.
struct PageDialogsPopupTest: E2ETest {
    let name = "dialogs.popup_window"

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        let (message, modal, sheet) = try await run.step(
            "open a popup window that asks", timeout: E2ETimeouts.firstLoad
        ) {
            try await page.click("#popup")
            let message = try await E2EWaits.until(page, "window.bowMessages.find((m) => m.startsWith('popup:'))")
            return (message as? String ?? "", app.appModalPanelShown, try app.pageDialog(besides: page))
        }
        run.check(
            name, passed: message == "popup:undefined:false" && !modal && sheet == nil,
            "popup=\(message) app-modal=\(modal) sheet=\(PageDialogsTests.describe(sheet))")
    }
}
