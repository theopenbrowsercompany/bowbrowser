import Foundation

// Tests of a popup panel page's alert, confirm and prompt (see PageDialogs.swift for the area). Fixture:
// E2E/Fixtures/dialogs/panel-sheet.html, opened in a popup panel by page.html's #panel button.

extension PageDialogsTests {
    /// Waits for the sheet on the newest popup panel over `page`'s window showing `message`.
    static func untilPanelDialog(_ app: any E2EPageDialogsApp, besides page: any E2EPage, message: String) async throws
        -> E2EPageDialog
    {
        var dialog: E2EPageDialog?
        guard
            try await TabEdgesTests.until({
                dialog = try app.panelDialog(besides: page)
                return dialog?.message == message
            }), let dialog
        else {
            throw E2EError("no popup panel sheet showed \"\(message)\" (last: \(describe(dialog)))")
        }
        return dialog
    }

    /// Clicks the opener's #panel button (a sized `window.open` from a click opens panel-sheet.html in a popup panel)
    /// and waits until the panel's page is ready.
    static func openAskingPanel(_ run: E2ERun, page: any E2EPage) async throws {
        try await run.step("open a popup panel", timeout: E2ETimeouts.firstLoad) {
            try await page.click("#panel")
            _ = try await E2EWaits.until(page, "window.bowMessages.includes('panel-ready')")
        }
    }

    /// Tells the panel's page what to do (see panel-sheet.html), from its opener.
    static func tellPanel(_ page: any E2EPage, _ command: String) async throws {
        _ = try await page.evaluate("window.bowPanel.postMessage('\(command)', '*'); true")
    }
}

/// A popup panel page's alert, confirm and prompt come up as sheets on the panel (never on the window under it, never
/// app modal, off screen here like the panel), titled with the page's origin; the page gets OK on the alert, true and
/// false from the confirms and the typed text from the prompt. Two alerts in a row come up one after the other, and a
/// dialog asked while the panel's opener tab is hidden still shows on the panel.
struct PageDialogsPanelSheetTest: E2ETest {
    let name = "dialogs.panel_sheet"
    let checks = ["dialogs.panel_sheet", "dialogs.panel_twice", "dialogs.panel_hidden_opener"]

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        let page = try await PageDialogsTests.openWindow(run)
        try await PageDialogsTests.openAskingPanel(run, page: page)
        try await PageDialogsTests.tellPanel(page, "go")

        var seen: [E2EPageDialog] = []
        var onWindow: [E2EPageDialog?] = []
        var modal = false
        var offScreen = true
        let steps: [(String, Bool, String?)] = [
            ("panel alert", true, nil), ("panel confirm one", true, nil), ("panel confirm two", false, nil),
            ("panel prompt", true, "typed in the panel"),
        ]
        for (message, accept, text) in steps {
            try await run.step("answer \"\(message)\"", timeout: E2ETimeouts.step) {
                seen.append(try await PageDialogsTests.untilPanelDialog(app, besides: page, message: message))
                onWindow.append(try app.pageDialog(besides: page))
                modal = modal || app.appModalPanelShown
                offScreen = try offScreen && app.panelDialogIsOffScreen(besides: page)
                try app.answerPanelDialog(besides: page, accept: accept, text: text)
            }
        }
        let (answers, after) = try await run.step("read what the panel got back", timeout: E2ETimeouts.step) {
            _ = try await E2EWaits.until(page, "window.bowMessages.some((m) => m.startsWith('panel-prompt:'))")
            let answers = try await page.string(
                "window.bowMessages.filter((m) => m.startsWith('panel-') && m !== 'panel-ready').join(',')")
            return (answers, try app.panelDialog(besides: page))
        }
        func expect(_ message: String, _ buttons: [String], _ field: String? = nil) -> E2EPageDialog {
            E2EPageDialog(
                title: "bow.test says", message: message, buttons: buttons, field: field, isAttached: true)
        }
        let expected = [
            expect("panel alert", ["OK"]), expect("panel confirm one", ["OK", "Cancel"]),
            expect("panel confirm two", ["OK", "Cancel"]), expect("panel prompt", ["OK", "Cancel"], "default text"),
        ]
        let expectedAnswers =
            "panel-alert:undefined,panel-confirm-ok:true,panel-confirm-cancel:false,panel-prompt:typed in the panel"
        run.check(
            "dialogs.panel_sheet",
            passed: seen == expected && onWindow.allSatisfy { $0 == nil } && !modal && offScreen
                && answers == expectedAnswers && after == nil,
            "sheets=\(seen.map(\.description).joined(separator: "; ")) on-window=\(onWindow.compactMap { $0 }.count) "
                + "app-modal=\(modal) off-screen=\(offScreen) page=\(answers) after=\(PageDialogsTests.describe(after))"
        )

        // Two alerts in a row: the second comes up once the first is answered.
        try await PageDialogsTests.tellPanel(page, "twice")
        let (firstUp, secondUp, twiceDone) = try await run.step("answer two alerts in a row", timeout: E2ETimeouts.step)
        {
            let first = try await PageDialogsTests.untilPanelDialog(app, besides: page, message: "panel alert one")
            try app.answerPanelDialog(besides: page, accept: true, text: nil)
            let second = try await PageDialogsTests.untilPanelDialog(app, besides: page, message: "panel alert two")
            try app.answerPanelDialog(besides: page, accept: true, text: nil)
            _ = try await E2EWaits.until(page, "window.bowMessages.includes('panel-twice:done')")
            return (first.isAttached, second.isAttached, try app.panelDialog(besides: page) == nil)
        }
        run.check(
            "dialogs.panel_twice", passed: firstUp && secondUp && twiceDone,
            "first=\(firstUp) second=\(secondUp) after-none=\(twiceDone)")

        // The opener tab goes to the background: the panel's page still has its dialog on the panel.
        let (hidden, hiddenAnswer) = try await run.step("ask while the opener tab is hidden", timeout: E2ETimeouts.step)
        {
            _ = try await PageDialogsTests.openTab(run, "B", besides: page, select: true)
            try await PageDialogsTests.tellPanel(page, "wait")
            let dialog = try await PageDialogsTests.untilPanelDialog(
                app, besides: page, message: "waiting in the panel")
            try app.answerPanelDialog(besides: page, accept: true, text: nil)
            _ = try await E2EWaits.until(page, "window.bowMessages.includes('panel-wait:true')")
            return (dialog.isAttached, try app.panelDialog(besides: page) == nil)
        }
        run.check(
            "dialogs.panel_hidden_opener", passed: hidden && hiddenAnswer,
            "attached=\(hidden) after-none=\(hiddenAnswer)")
    }
}

/// A popup panel closed with its sheet up answers it once as cancelled and leaves nothing open: closed as its close
/// button does, its opener tab closed, or its window closed. The page that opened it keeps working (it shares its page
/// group with the panel, so it could not run a script while a dialog stayed unanswered).
struct PageDialogsPanelCloseTest: E2ETest {
    let name = "dialogs.panel_close"
    let checks = ["dialogs.panel_close", "dialogs.panel_opener_close", "dialogs.panel_window_close"]

    func run(_ run: E2ERun) async throws {
        let app = try PageDialogsTests.dialogsApp(run)
        guard let popups = run.app as? any E2EPopupsApp else { throw E2EError("the app has no popups") }
        let page = try await PageDialogsTests.openWindow(run)
        try await PageDialogsTests.openAskingPanel(run, page: page)
        try await PageDialogsTests.tellPanel(page, "wait")
        let (closed, sheet, modal, alive) = try await run.step(
            "close the panel with a confirm up", timeout: E2ETimeouts.step
        ) {
            _ = try await PageDialogsTests.untilPanelDialog(app, besides: page, message: "waiting in the panel")
            try popups.closePopupPanel(besides: page)
            let closed = try await TabEdgesTests.until({ try popups.popupPanels(besides: page).isEmpty })
            // The opener runs scripts again only once the dialog is answered.
            let alive = try await page.evaluate("1 + 1") as? Int == 2
            return (closed, try app.panelDialog(besides: page), app.appModalPanelShown, alive)
        }
        run.check(
            "dialogs.panel_close", passed: closed && sheet == nil && !modal && alive,
            "closed=\(closed) sheet=\(PageDialogsTests.describe(sheet)) app-modal=\(modal) opener-alive=\(alive)")

        let opener = try await PageDialogsTests.openTab(run, "C", besides: page, select: true)
        try await PageDialogsTests.openAskingPanel(run, page: opener)
        try await PageDialogsTests.tellPanel(opener, "wait")
        let (tabClosed, panels, sheetAfter, otherAlive) = try await run.step(
            "close the opener tab with a confirm up", timeout: E2ETimeouts.step
        ) {
            _ = try await PageDialogsTests.untilPanelDialog(app, besides: opener, message: "waiting in the panel")
            let closed = try await run.app.closeTab(opener)
            let panels = try popups.popupPanels(besides: page).count
            let alive = try await page.evaluate("1 + 1") as? Int == 2
            return (closed, panels, try app.panelDialog(besides: page), alive)
        }
        run.check(
            "dialogs.panel_opener_close", passed: tabClosed && panels == 0 && sheetAfter == nil && otherAlive,
            "closed=\(tabClosed) panels=\(panels) sheet=\(PageDialogsTests.describe(sheetAfter)) alive=\(otherAlive)")

        let second = try await PageDialogsTests.openWindow(run, "W")
        try await PageDialogsTests.openAskingPanel(run, page: second)
        try await PageDialogsTests.tellPanel(second, "wait")
        let windowModal = try await run.step("close the window with a confirm up", timeout: E2ETimeouts.step) {
            _ = try await PageDialogsTests.untilPanelDialog(app, besides: second, message: "waiting in the panel")
            try await run.app.closeWindow(of: second)
            return app.appModalPanelShown
        }
        run.check(
            "dialogs.panel_window_close", passed: second.isClosed && !windowModal,
            "closed=\(second.isClosed) app-modal=\(windowModal)")
    }
}
