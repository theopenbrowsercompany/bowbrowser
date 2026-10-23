import Foundation

/// Tests of a page's alert, confirm and prompt: each comes up as a sheet on the window showing its tab, titled with
/// the page's origin, and the page gets the answer pressed on the sheet; a tab the window does not show has its alert
/// answered at once and shown when the tab is, and its confirm and prompt cancelled; switching away, navigating,
/// closing the tab or the window take the sheet down; a popup window's dialog never blocks the app. No dialog is ever
/// an app modal panel. Fixtures in E2E/Fixtures/dialogs/: page.html asks through `bowAsk(kind, message, value)` and
/// records what it got back in `bowResults`; relay.html, opened in a popup panel by a sized `window.open`, opens a page in
/// a popup window of the engine's own on a click and passes messages both ways; popup.html, opened so, asks as it loads;
/// popup-sheet.html, opened in a real off screen popup window (`E2EPopupWindowsApp`), asks once its opener posts "go"
/// and tells the opener each answer.
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
        PageDialogsPopupSheetTest(),
        PageDialogsPopupSheetQuitTest(),
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

/// A popup window of the engine's own (opened by a popup panel's page) asking for an alert and a confirm never blocks
/// the app: an e2e run parks popups in no window, so both are answered at once as cancelled, and no app modal panel
/// shows.
struct PageDialogsPopupTest: E2ETest {
    let name = "dialogs.popup_window"

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let popups = try PageDialogsTests.popupWindowsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        let (message, modal, sheet) = try await run.step(
            "open a popup window that asks", timeout: E2ETimeouts.firstLoad
        ) {
            try await PageDialogsTests.openPopupWindow(popups, page: page, button: "#popup")
            let message = try await E2EWaits.until(page, "window.bowMessages.find((m) => m.startsWith('popup:'))")
            return (message as? String ?? "", app.appModalPanelShown, try app.pageDialog(besides: page))
        }
        run.check(
            name, passed: message == "popup:undefined:false" && !modal && sheet == nil,
            "popup=\(message) app-modal=\(modal) sheet=\(PageDialogsTests.describe(sheet))")
    }
}

extension PageDialogsTests {
    static func popupWindowsApp(_ run: E2ERun) throws -> any E2EPopupWindowsApp {
        guard let app = run.app as? any E2EPopupWindowsApp else { throw E2EError("the app has no popup windows") }
        return app
    }

    /// Clicks `button` in `page`, which opens relay.html in a popup panel, then clicks #open in the panel's page,
    /// which opens the relay's page in a popup window of the engine's own (the pages a panel's page opens go there).
    static func openPopupWindow(_ popups: any E2EPopupWindowsApp, page: any E2EPage, button: String) async throws {
        try await page.click(button)
        _ = try await E2EWaits.until(
            page,
            "window.bowPopup && window.bowPopup.document.readyState === 'complete' "
                + "&& window.bowPopup.document.getElementById('open')")
        let panel = try popups.popupPanelPage(besides: page)
        try await panel.click("#open")
    }

    /// Opens popup-sheet.html in a hosted popup window through `button` (`openPopupWindow`), waits until it is
    /// ready, and posts it "go". Returns how many hosted popup windows are open then.
    static func openAskingPopup(
        _ run: E2ERun, _ popups: any E2EPopupWindowsApp, page: any E2EPage, button: String
    ) async throws -> Int {
        try await run.step("open a popup window that asks", timeout: E2ETimeouts.firstLoad) {
            try await openPopupWindow(popups, page: page, button: button)
            _ = try await E2EWaits.until(page, "window.bowMessages.includes('sheet-ready')")
            let windows = try popups.openPopupWindowCount()
            // After this the popup's dialogs hold the opener too (they share one page group), so nothing more is
            // asked of the opener until every dialog is answered.
            _ = try await page.evaluate("window.bowPopup.postMessage('go', '*'); true")
            return windows
        }
    }

    /// Waits for the popup window's sheet showing `message`.
    static func untilPopupDialog(_ popups: any E2EPopupWindowsApp, message: String) async throws -> E2EPageDialog {
        var dialog: E2EPageDialog?
        guard
            try await TabEdgesTests.until({
                dialog = try popups.popupWindowDialog()
                return dialog?.message == message
            }), let dialog
        else {
            throw E2EError("no popup window sheet showed \"\(message)\" (last: \(describe(dialog)))")
        }
        return dialog
    }
}

/// A popup window of the engine's own, here in a real window off screen, asks on that window: its alert, confirm and
/// prompt come up one at a time as sheets on the popup's window titled with its origin, never app modal, and the page
/// gets back OK on the alert, true for OK and false for Cancel on a confirm, and the text typed into a prompt.
struct PageDialogsPopupSheetTest: E2ETest {
    let name = "dialogs.popup_sheet"
    let checks = [
        "dialogs.popup_sheet.alert", "dialogs.popup_sheet.confirm", "dialogs.popup_sheet.prompt",
        "dialogs.popup_sheet.answers",
    ]

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let popups = try PageDialogsTests.popupWindowsApp(run)
        try popups.hostPopupWindows()
        defer { popups.stopHostingPopupWindows() }
        let page = try await PageDialogsTests.openWindow(run)
        let windows = try await PageDialogsTests.openAskingPopup(run, popups, page: page, button: "#popup-sheet")

        let (alert, alertModal) = try await run.step("press OK on the popup's alert", timeout: E2ETimeouts.step) {
            let dialog = try await PageDialogsTests.untilPopupDialog(popups, message: "popup alert")
            let modal = app.appModalPanelShown
            try popups.answerPopupWindowDialog(accept: true, text: nil)
            return (dialog, modal)
        }
        let expectedAlert = E2EPageDialog(
            title: "bow.test says", message: "popup alert", buttons: ["OK"], field: nil, isAttached: true)
        run.check(
            "dialogs.popup_sheet.alert", passed: windows == 1 && alert == expectedAlert && !alertModal,
            "windows=\(windows) \(alert) app-modal=\(alertModal)")

        var confirms: [E2EPageDialog] = []
        for (message, accept) in [("popup confirm one", true), ("popup confirm two", false)] {
            try await run.step("press \(accept ? "OK" : "Cancel") on a popup confirm", timeout: E2ETimeouts.step) {
                confirms.append(try await PageDialogsTests.untilPopupDialog(popups, message: message))
                try popups.answerPopupWindowDialog(accept: accept, text: nil)
            }
        }
        let expectedConfirms = ["popup confirm one", "popup confirm two"].map {
            E2EPageDialog(title: "bow.test says", message: $0, buttons: ["OK", "Cancel"], field: nil, isAttached: true)
        }
        run.check(
            "dialogs.popup_sheet.confirm", passed: confirms == expectedConfirms,
            confirms.map(\.description).joined(separator: "; "))

        let prompt = try await run.step("type into the popup's prompt and press OK", timeout: E2ETimeouts.step) {
            let dialog = try await PageDialogsTests.untilPopupDialog(popups, message: "popup prompt")
            try popups.answerPopupWindowDialog(accept: true, text: "typed in the popup")
            return dialog
        }
        let expectedPrompt = E2EPageDialog(
            title: "bow.test says", message: "popup prompt", buttons: ["OK", "Cancel"], field: "default text",
            isAttached: true)
        run.check("dialogs.popup_sheet.prompt", passed: prompt == expectedPrompt, prompt.description)

        let (answers, after) = try await run.step("read what the popup got back", timeout: E2ETimeouts.step) {
            _ = try await E2EWaits.until(page, "window.bowMessages.some((m) => m.startsWith('sheet-prompt:'))")
            let answers = try await page.string(
                "window.bowMessages.filter((m) => m.startsWith('sheet-') && m !== 'sheet-ready').join(',')")
            return (answers, try popups.popupWindowDialog())
        }
        let expectedAnswers =
            "sheet-alert:undefined,sheet-confirm-ok:true,sheet-confirm-cancel:false,sheet-prompt:typed in the popup"
        run.check(
            "dialogs.popup_sheet.answers", passed: answers == expectedAnswers && after == nil,
            "page=\(answers) sheet-after=\(PageDialogsTests.describe(after))")
    }
}

/// Quitting asks every page to close, popups included: a popup window with its alert up as a sheet closes on that
/// request (its sheet goes, its window closes and its page ends), so a sheet never refuses or holds up a quit.
struct PageDialogsPopupSheetQuitTest: E2ETest {
    let name = "dialogs.popup_sheet_quit"

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let popups = try PageDialogsTests.popupWindowsApp(run)
        try popups.hostPopupWindows()
        defer { popups.stopHostingPopupWindows() }
        let page = try await PageDialogsTests.openWindow(run)
        _ = try await PageDialogsTests.openAskingPopup(run, popups, page: page, button: "#popup-wait")
        let dialog = try await run.step("wait for the popup's alert", timeout: E2ETimeouts.step) {
            try await PageDialogsTests.untilPopupDialog(popups, message: "waiting in the popup")
        }
        let (closed, windows, modal) = try await run.step(
            "close the popup as quitting does", timeout: E2ETimeouts.step
        ) {
            try popups.closePopupWindowAsQuitDoes()
            let closed = try await TabEdgesTests.until({ try popups.openPopupWindowCount() == 0 })
            let modal = app.appModalPanelShown
            // The page ends with its window, so the opener sees its popup closed.
            if closed { _ = try await E2EWaits.until(page, "window.bowPopup.bowChild.closed") }
            return (closed, try popups.openPopupWindowCount(), modal)
        }
        run.check(
            name, passed: dialog.isAttached && closed && windows == 0 && !modal,
            "sheet=\(dialog) windows-after=\(windows) app-modal=\(modal)")
    }
}
