import Foundation

/// Tests of the sign in sheet and the certificate error page, against the loopback fixtures (`E2ELoopback`): a page
/// answering 401 brings up a sheet on its window naming who asks, with user name and password fields, Sign In and
/// Cancel; Sign In loads the page, Cancel shows the site's 401 page, a wrong password asks again, and closing the tab,
/// navigating, switching tabs or closing the window with the sheet up answers the question exactly once and leaves
/// nothing open. A page whose certificate fails shows the certificate error page over the tab, with Go back as its
/// only action, and the site never sees a request. Each sign in test asks in a realm no earlier attempt used, since
/// the engine remembers a realm's credentials for the session. Fixture: E2E/Fixtures/auth/index.html, the page a test
/// starts from.
@MainActor
enum AuthTests {
    static let all: [any E2ETest] = [
        AuthSignInTest(),
        AuthCancelTest(),
        AuthRetryTest(),
        AuthCloseTest(),
        CertificatePageTest(),
    ]

    static let startURL = E2EFixture.url("auth/index.html")
    private static var realmCount = 0

    /// A sign in URL in a realm named after `name` that no earlier attempt in this run used.
    static func freshRealm(_ name: String) -> (url: URL, realm: String) {
        realmCount += 1
        let realm = "\(name)\(realmCount)"
        return (URL(string: "http://\(E2ELoopback.authHost)/realm/\(realm)/")!, realm)
    }

    /// The sheet's text for `realm` on the loopback sign in fixture.
    static func message(_ realm: String) -> String {
        "\(E2ELoopback.authHost) asks for a user name and password for \u{201C}\(realm)\u{201D}. "
            + "Your connection to this site is not private."
    }

    static func apps(_ run: E2ERun) throws -> (auth: any E2EAuthApp, challenges: any E2EChallengesApp) {
        guard let auth = run.app as? any E2EAuthApp, let challenges = run.app as? any E2EChallengesApp else {
            throw E2EError("the app has no sign in sheet")
        }
        return (auth, challenges)
    }

    /// Opens a window on the start page and records the challenges its tab asks.
    static func openWindow(_ run: E2ERun, _ challenges: any E2EChallengesApp) async throws -> any E2EPage {
        try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: startURL)
            _ = try await page.waitForLoad(after: 0)
            try challenges.recordChallenges(of: page)
            return page
        }
    }

    /// Waits for a sign in sheet on `page`'s window.
    static func untilSheet(_ app: any E2EAuthApp, besides page: any E2EPage) async throws -> E2ESignInSheet {
        var sheet: E2ESignInSheet?
        guard
            try await E2EWaits.until({
                sheet = try app.signInSheet(besides: page)
                return sheet != nil
            }), let sheet
        else { throw E2EError("no sign in sheet came up") }
        return sheet
    }

    /// Waits until `page` has recorded `count` sign in questions and the last is answered.
    static func untilAnswered(_ challenges: any E2EChallengesApp, _ page: any E2EPage, count: Int) async throws
        -> [E2EAuthQuestion]
    {
        var questions: [E2EAuthQuestion] = []
        _ = try await E2EWaits.until {
            questions = try challenges.authChallenges(of: page)
            return questions.count >= count && questions.allSatisfy(\.answered)
        }
        return questions
    }

    /// The page's last finished or failed load.
    static func lastEnd(_ page: any E2EPage) -> String {
        page.navigationEvents.last { $0.kind == .finish || $0.kind == .fail }.map(\.description) ?? "none"
    }

    static func describe(_ sheet: E2ESignInSheet?) -> String { sheet.map(\.description) ?? "none" }
}

/// A page answering 401 brings up the sign in sheet on its window, naming the host and realm, with empty user name and
/// password fields, Sign In (the default) and Cancel; Sign In with the right password loads the page.
struct AuthSignInTest: E2ETest {
    let name = "auth"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        let fixtures = try E2ELoopback.running()
        let page = try await AuthTests.openWindow(run, challenges)
        let (url, realm) = AuthTests.freshRealm("signin")
        let authorized = fixtures.authorizedRequests
        let (sheet, loads) = try await run.step("load a page that asks to sign in", timeout: E2ETimeouts.firstLoad) {
            let loads = page.finishedLoads
            try page.load(url)
            return (try await AuthTests.untilSheet(app, besides: page), loads)
        }
        let (title, questions, idle) = try await run.step("sign in", timeout: E2ETimeouts.firstLoad) {
            try app.answerSignInSheet(besides: page, user: E2ELoopback.authUser, password: E2ELoopback.authPassword)
            _ = try await page.waitForLoad(after: loads)
            let questions = try await AuthTests.untilAnswered(challenges, page, count: 1)
            return (try await page.string("document.title"), questions, try app.signInIdle(besides: page))
        }
        let expected = E2ESignInSheet(
            title: "Sign in", message: AuthTests.message(realm), buttons: ["Sign In", "Cancel"],
            defaultButton: "Sign In",
            fieldsReady: true, isAttached: true)
        let signedIn = fixtures.authorizedRequests - authorized
        run.check(
            name,
            passed: sheet == expected && title == "Signed in" && questions.count == 1
                && questions.first?.answeredUser == E2ELoopback.authUser && questions.first?.realm == realm
                && signedIn == 1 && idle,
            "prompted=true \(sheet) title=\(title) questions=\(questions) signed-in=\(signedIn) idle=\(idle)")
    }
}

/// Cancel on the sign in sheet answers cancelled: the page shows the site's own 401 page and the site sees no
/// credentials.
struct AuthCancelTest: E2ETest {
    let name = "auth.cancel"

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        let fixtures = try E2ELoopback.running()
        let page = try await AuthTests.openWindow(run, challenges)
        let (url, _) = AuthTests.freshRealm("cancel")
        let authorized = fixtures.authorizedRequests
        let (title, questions, end, idle) = try await run.step("cancel the sign in", timeout: E2ETimeouts.firstLoad) {
            let loads = page.finishedLoads
            try page.load(url)
            _ = try await AuthTests.untilSheet(app, besides: page)
            try app.answerSignInSheet(besides: page, user: nil, password: nil)
            _ = try await page.waitForLoad(after: loads)
            let questions = try await AuthTests.untilAnswered(challenges, page, count: 1)
            return (
                try await page.string("document.title"), questions, AuthTests.lastEnd(page),
                try app.signInIdle(besides: page)
            )
        }
        let signedIn = fixtures.authorizedRequests - authorized
        run.check(
            name,
            passed: title == "Sign in required" && end.hasSuffix(" 401") && questions.count == 1
                && questions.first?.answeredUser == nil && signedIn == 0 && idle,
            "title=\(title) end=\(end) questions=\(questions) signed-in=\(signedIn) idle=\(idle)")
    }
}

/// A wrong password makes the site ask again, which brings up a new sheet; the right password then loads the page.
/// Each question is answered once.
struct AuthRetryTest: E2ETest {
    let name = "auth.retry"

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        let fixtures = try E2ELoopback.running()
        let page = try await AuthTests.openWindow(run, challenges)
        let (url, realm) = AuthTests.freshRealm("retry")
        let authorized = fixtures.authorizedRequests
        let unauthorized = fixtures.unauthorizedRequests
        let (first, loads) = try await run.step("load a page that asks to sign in", timeout: E2ETimeouts.firstLoad) {
            let loads = page.finishedLoads
            try page.load(url)
            return (try await AuthTests.untilSheet(app, besides: page), loads)
        }
        let second = try await run.step("sign in with a wrong password", timeout: E2ETimeouts.step) {
            try app.answerSignInSheet(besides: page, user: E2ELoopback.authUser, password: "wrong")
            _ = try await E2EWaits.until { try challenges.authChallenges(of: page).count >= 2 }
            return try await AuthTests.untilSheet(app, besides: page)
        }
        let (title, questions) = try await run.step("sign in with the right password", timeout: E2ETimeouts.step) {
            try app.answerSignInSheet(besides: page, user: E2ELoopback.authUser, password: E2ELoopback.authPassword)
            _ = try await page.waitForLoad(after: loads)
            let questions = try await AuthTests.untilAnswered(challenges, page, count: 2)
            return (try await page.string("document.title"), questions)
        }
        let signedIn = fixtures.authorizedRequests - authorized
        let refused = fixtures.unauthorizedRequests - unauthorized
        run.check(
            name,
            passed: first.message == AuthTests.message(realm) && second.message == AuthTests.message(realm)
                && second.fieldsReady && title == "Signed in" && questions.count == 2
                && questions.allSatisfy { $0.answered && $0.answeredUser == E2ELoopback.authUser } && signedIn == 1
                && refused == 2,
            "first=\(first) second=\(second) title=\(title) questions=\(questions) signed-in=\(signedIn) "
                + "refused=\(refused)")
    }
}

/// Closing the tab with the sheet up answers the question once (cancelled) and leaves no sheet or request behind;
/// so do a navigation and closing the window. A question from a tab the window does not show waits, unanswered, and
/// comes up when its tab is shown; switching away takes it down and switching back brings it again.
struct AuthCloseTest: E2ETest {
    let name = "auth.close"
    let checks = ["auth.close", "auth.navigate", "auth.background", "auth.close_window"]

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        let page = try await AuthTests.openWindow(run, challenges)

        let other = try await run.step("open a tab", timeout: E2ETimeouts.firstLoad) {
            let tab = try run.app.openTab(at: AuthTests.startURL, besides: page, select: true)
            _ = try await tab.waitForLoad(after: 0)
            try challenges.recordChallenges(of: tab)
            return tab
        }
        let (closed, questions, sheet, idle, modal) = try await run.step(
            "close the tab with the sheet up", timeout: E2ETimeouts.firstLoad
        ) {
            try other.load(AuthTests.freshRealm("close").url)
            _ = try await AuthTests.untilSheet(app, besides: page)
            let closed = try await run.app.closeTab(other)
            let questions = try await AuthTests.untilAnswered(challenges, other, count: 1)
            return (
                closed, questions, try app.signInSheet(besides: page), try app.signInIdle(besides: page),
                (run.app as? any E2EPageDialogsApp)?.appModalPanelShown ?? false
            )
        }
        run.check(
            "auth.close",
            passed: closed && other.isClosed && questions.count == 1 && questions.first?.answered == true
                && questions.first?.answeredUser == nil && sheet == nil && idle && !modal,
            "closed=\(closed) questions=\(questions) sheet=\(AuthTests.describe(sheet)) idle=\(idle) "
                + "app-modal=\(modal)")

        let (navigated, navigatedQuestions, navigatedIdle) = try await run.step(
            "navigate with the sheet up", timeout: E2ETimeouts.firstLoad
        ) {
            try page.load(AuthTests.freshRealm("navigate").url)
            _ = try await AuthTests.untilSheet(app, besides: page)
            // The sign in load fails as aborted when the new one replaces it, so wait for the new one's finish.
            let events = page.navigationEvents.count
            try page.load(AuthTests.startURL)
            _ = try await E2EWaits.until {
                page.navigationEvents[events...].contains { $0.kind == .finish && $0.url == AuthTests.startURL }
            }
            let questions = try await AuthTests.untilAnswered(challenges, page, count: 1)
            return (AuthTests.lastEnd(page), questions, try app.signInIdle(besides: page))
        }
        run.check(
            "auth.navigate",
            passed: navigated == "finish /auth/index.html 200" && navigatedQuestions.count == 1
                && navigatedQuestions.first?.answeredUser == nil && navigatedIdle,
            "end=\(navigated) questions=\(navigatedQuestions) idle=\(navigatedIdle)")

        let background = try await run.step("open a background tab", timeout: E2ETimeouts.firstLoad) {
            let tab = try run.app.openTab(at: AuthTests.startURL, besides: page, select: false)
            _ = try await tab.waitForLoad(after: 0)
            try challenges.recordChallenges(of: tab)
            return tab
        }
        let (hiddenSheet, waits, hiddenQuestions, shown, awaySheet, back, final) = try await run.step(
            "sign in from the background", timeout: E2ETimeouts.firstLoad
        ) {
            let loads = background.finishedLoads
            try background.load(AuthTests.freshRealm("background").url)
            _ = try await E2EWaits.until { try challenges.authChallenges(of: background).count == 1 }
            let hiddenSheet = try app.signInSheet(besides: page)
            let waits = try app.signInWaits(for: background)
            let hiddenQuestions = try challenges.authChallenges(of: background)
            try run.app.select(background)
            let shown = try await AuthTests.untilSheet(app, besides: page)
            try run.app.select(page)
            let awaySheet = try app.signInSheet(besides: page)
            try run.app.select(background)
            let back = try await AuthTests.untilSheet(app, besides: page)
            try app.answerSignInSheet(besides: page, user: nil, password: nil)
            _ = try await background.waitForLoad(after: loads)
            return (
                hiddenSheet, waits, hiddenQuestions, shown, awaySheet, back,
                try await AuthTests.untilAnswered(challenges, background, count: 1)
            )
        }
        run.check(
            "auth.background",
            passed: hiddenSheet == nil && waits && hiddenQuestions.first?.answered == false && shown.isAttached
                && awaySheet == nil && back.isAttached && final.count == 1 && final.first?.answeredUser == nil,
            "hidden-sheet=\(AuthTests.describe(hiddenSheet)) waits=\(waits) hidden=\(hiddenQuestions) "
                + "shown=\(shown.isAttached) away=\(AuthTests.describe(awaySheet)) back=\(back.isAttached) "
                + "final=\(final)")

        let second = try await AuthTests.openWindow(run, challenges)
        let (windowQuestions, windowModal) = try await run.step(
            "close the window with the sheet up", timeout: E2ETimeouts.firstLoad
        ) {
            try second.load(AuthTests.freshRealm("window").url)
            _ = try await AuthTests.untilSheet(app, besides: second)
            try await run.app.closeWindow(of: second)
            let questions = try await AuthTests.untilAnswered(challenges, second, count: 1)
            return (questions, (run.app as? any E2EPageDialogsApp)?.appModalPanelShown ?? false)
        }
        run.check(
            "auth.close_window",
            passed: second.isClosed && windowQuestions.count == 1 && windowQuestions.first?.answered == true
                && windowQuestions.first?.answeredUser == nil && !windowModal,
            "closed=\(second.isClosed) questions=\(windowQuestions) app-modal=\(windowModal)")
    }
}

/// A page whose certificate fails shows the certificate error page over the tab: the title, the host and the error in
/// plain words, and Go back as its only (so default) action; the site sees no request. Go back returns to the page before;
/// in a tab with no page before, it closes the tab.
struct CertificatePageTest: E2ETest {
    let name = "cert.page"
    let checks = ["cert.page", "cert.no_history"]

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        let fixtures = try E2ELoopback.runningWithCertificate()
        let page = try await AuthTests.openWindow(run, challenges)
        let served = fixtures.certificateRequests
        let shown = try await run.step("load a page with a bad certificate", timeout: E2ETimeouts.firstLoad) {
            try page.load(E2ELoopback.badCertificateURL)
            var shown: E2ECertificateErrorPage?
            guard
                try await E2EWaits.until({
                    shown = try app.certificateErrorPage(besides: page)
                    return shown != nil
                }), let shown
            else { throw E2EError("no certificate error page came up") }
            return shown
        }
        let questions = try challenges.certificateErrors(of: page)
        let (back, after) = try await run.step("press Go back", timeout: E2ETimeouts.firstLoad) {
            try app.pressCertificateGoBack(besides: page)
            _ = try await E2EWaits.until { try app.certificateErrorPage(besides: page) == nil }
            _ = try await E2EWaits.until(page, "document.title === 'Auth start'")
            return (try await page.string("location.href"), try app.certificateErrorPage(besides: page))
        }
        let host = E2ELoopback.certificateHost
        let expectedMessage =
            "Bow could not confirm that this is the real \(host). "
            + "Its certificate is not from an authority this Mac trusts. "
            + "Someone might be trying to steal what you send to it, such as passwords, messages or card numbers."
        let requests = fixtures.certificateRequests - served
        run.check(
            "cert.page",
            passed: shown.title == "This connection is not secure" && shown.message == expectedMessage
                && shown.detail == "NET::ERR_CERT_AUTHORITY_INVALID" && shown.buttons == ["Go back"]
                && questions.count == 1 && questions.first?.proceeded == false
                && requests == 0 && back == AuthTests.startURL.absoluteString && after == nil,
            "\(shown) questions=\(questions) served=\(requests) back=\(back) after=\(after.map(\.title) ?? "none")")

        let (fresh, closed, afterClose) = try await run.step(
            "Go back in a tab with no page before", timeout: E2ETimeouts.firstLoad
        ) {
            let tab = try run.app.openTab(at: E2ELoopback.badCertificateURL, besides: page, select: true)
            var fresh: E2ECertificateErrorPage?
            _ = try await E2EWaits.until {
                fresh = try app.certificateErrorPage(besides: page)
                return fresh != nil
            }
            try app.pressCertificateGoBack(besides: page)
            _ = try await E2EWaits.until { tab.isClosed }
            return (fresh, tab.isClosed, try app.certificateErrorPage(besides: page))
        }
        run.check(
            "cert.no_history",
            passed: fresh?.buttons == ["Go back"] && closed && afterClose == nil && page.isShown
                && fixtures.certificateRequests == served,
            "page=\(fresh.map(\.title) ?? "none") closed=\(closed) after=\(afterClose.map(\.title) ?? "none") "
                + "shown=\(page.isShown) served=\(fixtures.certificateRequests - served)")
    }
}
