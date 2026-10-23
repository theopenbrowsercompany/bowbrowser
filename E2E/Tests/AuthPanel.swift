import Foundation

// Tests of a popup panel page's sign in (see Auth.swift for the area). Fixtures: E2E/Fixtures/auth/index.html, whose
// #panel button opens E2E/Fixtures/auth/panel.html in a popup panel, which goes where its opener tells it.

extension AuthTests {
    /// Opens a popup panel from `page`, records its sign in questions, sends it to a sign in page in a fresh realm
    /// named after `name`, and waits for the panel's sign in sheet. Returns the realm, the sheet and the recording.
    static func panelAsking(_ run: E2ERun, _ app: any E2EAuthApp, from page: any E2EPage, _ name: String)
        async throws -> (realm: String, sheet: E2ESignInSheet, questions: any E2EAuthRecording)
    {
        try await run.step("open a popup panel that asks to sign in", timeout: E2ETimeouts.firstLoad) {
            _ = try await page.evaluate("window.bowMessages.length = 0; true")
            try await page.click("#panel")
            _ = try await E2EWaits.until(page, "window.bowMessages.includes('panel-ready')")
            let questions = try app.recordPanelChallenges(besides: page)
            let (url, realm) = freshRealm(name)
            _ = try await page.evaluate("window.bowPanel.postMessage('go:\(url.absoluteString)', '*'); true")
            var sheet: E2ESignInSheet?
            guard
                try await E2EWaits.until({
                    sheet = try app.panelSignInSheet(besides: page)
                    return sheet != nil
                }), let sheet
            else { throw E2EError("no sign in sheet came up on the popup panel") }
            return (realm, sheet, questions)
        }
    }
}

/// A popup panel page asking to sign in gets the sign in sheet on the panel (never on the window under it, never app
/// modal, off screen here like the panel), and Sign In loads the page in the panel. Closing the panel, its opener tab
/// or its window with the sheet up answers the question exactly once, as cancelled, and leaves nothing open.
struct AuthPanelTest: E2ETest {
    let name = "auth.panel"
    let checks = ["auth.panel", "auth.panel_close", "auth.panel_opener_close", "auth.panel_window_close"]

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        guard let popups = run.app as? any E2EPopupsApp & E2EPageDialogsApp else {
            throw E2EError("the app has no popup panels")
        }
        let fixtures = try E2ELoopback.running()
        let page = try await AuthTests.openWindow(run, challenges)
        let authorized = fixtures.authorizedRequests
        let (realm, sheet, recording) = try await AuthTests.panelAsking(run, app, from: page, "panel")
        let onWindow = try app.signInSheet(besides: page)
        let modal = popups.appModalPanelShown
        let (title, questions, after) = try await run.step("sign in on the panel", timeout: E2ETimeouts.firstLoad) {
            try app.answerPanelSignInSheet(
                besides: page, user: E2ELoopback.authUser, password: E2ELoopback.authPassword)
            var title = ""
            _ = try await E2EWaits.until {
                title = try popups.popupPanels(besides: page).last?.title ?? ""
                return title == "Signed in"
            }
            return (title, try await Self.untilAnswered(recording), try app.panelSignInSheet(besides: page))
        }
        let expected = E2ESignInSheet(
            title: "Sign in", message: AuthTests.message(realm), buttons: ["Sign In", "Cancel"],
            defaultButton: "Sign In", fieldsReady: true, isAttached: true, offScreen: true)
        let signedIn = fixtures.authorizedRequests - authorized
        run.check(
            "auth.panel",
            passed: sheet == expected && onWindow == nil && !modal && title == "Signed in" && questions.count == 1
                && questions.first?.answeredUser == E2ELoopback.authUser && signedIn == 1 && after == nil,
            "\(sheet) on-window=\(AuthTests.describe(onWindow)) app-modal=\(modal) title=\(title) "
                + "questions=\(questions) signed-in=\(signedIn) after=\(AuthTests.describe(after))")
        try await run.step("close the signed in panel", timeout: E2ETimeouts.step) {
            try popups.closePopupPanel(besides: page)
            try await popups.untilNoPopupPanels(besides: page)
        }

        // The panel closed as its close button does, with the sheet up.
        let closing = try await AuthTests.panelAsking(run, app, from: page, "panelclose").questions
        let (closeQuestions, closeModal, alive, idle) = try await run.step(
            "close the panel with the sheet up", timeout: E2ETimeouts.step
        ) {
            try popups.closePopupPanel(besides: page)
            try await popups.untilNoPopupPanels(besides: page)
            let questions = try await Self.untilAnswered(closing)
            let alive = try await page.evaluate("1 + 1") as? Int == 2
            return (questions, popups.appModalPanelShown, alive, try app.signInIdle(besides: page))
        }
        run.check(
            "auth.panel_close",
            passed: Self.answeredOnceCancelled(closeQuestions) && !closeModal && alive && idle,
            "questions=\(closeQuestions) app-modal=\(closeModal) opener-alive=\(alive) window-idle=\(idle)")

        // The opener tab closed with the sheet up.
        let opener = try await run.step("open an opener tab", timeout: E2ETimeouts.firstLoad) {
            let opener = try run.app.openTab(at: AuthTests.startURL, besides: page, select: true)
            _ = try await opener.waitForLoad(after: 0)
            _ = try await E2EWaits.until(opener, "Array.isArray(window.bowMessages)")
            return opener
        }
        let openerRecording = try await AuthTests.panelAsking(run, app, from: opener, "panelopener").questions
        let (tabClosed, panels, openerQuestions) = try await run.step(
            "close the opener tab with the sheet up", timeout: E2ETimeouts.step
        ) {
            let closed = try await run.app.closeTab(opener)
            try await popups.untilNoPopupPanels(besides: page)
            let panels = try popups.popupPanels(besides: page).count
            return (closed, panels, try await Self.untilAnswered(openerRecording))
        }
        run.check(
            "auth.panel_opener_close",
            passed: tabClosed && panels == 0 && Self.answeredOnceCancelled(openerQuestions),
            "closed=\(tabClosed) panels=\(panels) questions=\(openerQuestions)")

        // The window closed with the sheet up.
        let second = try await AuthTests.openWindow(run, challenges)
        let windowRecording = try await AuthTests.panelAsking(run, app, from: second, "panelwindow").questions
        let (windowModal, windowQuestions) = try await run.step(
            "close the window with the sheet up", timeout: E2ETimeouts.step
        ) {
            try await run.app.closeWindow(of: second)
            return (popups.appModalPanelShown, try await Self.untilAnswered(windowRecording))
        }
        run.check(
            "auth.panel_window_close",
            passed: second.isClosed && !windowModal && Self.answeredOnceCancelled(windowQuestions),
            "closed=\(second.isClosed) app-modal=\(windowModal) questions=\(windowQuestions)")
    }

    /// Waits until `recording` holds a question and every one is answered, and returns them.
    private static func untilAnswered(_ recording: any E2EAuthRecording) async throws -> [E2EAuthQuestion] {
        _ = try await E2EWaits.until { !recording.auth.isEmpty && recording.auth.allSatisfy(\.answered) }
        return recording.auth
    }

    /// One question, answered as cancelled.
    private static func answeredOnceCancelled(_ questions: [E2EAuthQuestion]) -> Bool {
        questions.count == 1 && questions[0].answered && questions[0].answeredUser == nil
    }
}
