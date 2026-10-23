import Foundation

// Tests of the certificate error page around the page itself (see Auth.swift for the area): the URL field under it,
// Return, and split view. Fixture: E2E/Fixtures/auth/index.html.

extension AuthTests {
    /// Loads the bad certificate page in `page` and waits for the certificate error page over it.
    static func loadBadCertificate(_ app: any E2EAuthApp, in page: any E2EPage, besides window: any E2EPage)
        async throws
    {
        try page.load(E2ELoopback.badCertificateURL)
        guard try await E2EWaits.until({ try app.certificateErrorPage(besides: window) != nil }) else {
            throw E2EError("no certificate error page came up")
        }
    }
}

/// Under the certificate error page the URL fields (the sidebar's and the top tabs layout's) show the address that
/// failed, marked not secure, never the address of the page before; Go back brings back that page's address with the
/// usual lock.
struct CertificateAddressTest: E2ETest {
    let name = "cert.address"

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        _ = try E2ELoopback.runningWithCertificate()
        let page = try await AuthTests.openWindow(run, challenges)
        let before = try app.addressFields(of: page)
        let under = try await run.step("load a page with a bad certificate", timeout: E2ETimeouts.firstLoad) {
            try await AuthTests.loadBadCertificate(app, in: page, besides: page)
            return try app.addressFields(of: page)
        }
        let after = try await run.step("press Go back", timeout: E2ETimeouts.firstLoad) {
            try app.pressCertificateGoBack(besides: page)
            _ = try await E2EWaits.until { try app.certificateErrorPage(besides: page) == nil }
            _ = try await E2EWaits.until(page, "document.title === 'Auth start'")
            var fields = try app.addressFields(of: page)
            _ = try await E2EWaits.until {
                fields = try app.addressFields(of: page)
                return !fields.sidebarNotSecure && fields.sidebarText == before.sidebarText
            }
            return fields
        }
        let start = "bow.test/auth/index.html"
        let failed = E2ELoopback.certificateHost
        run.check(
            name,
            passed: before.sidebarText == start && !before.sidebarNotSecure
                && under
                    == E2EAddressFields(
                        sidebarText: failed, sidebarNotSecure: true, topTabsText: failed, topTabsNotSecure: true)
                // The top tabs field, hidden in the sidebar layout, goes back to what it showed before.
                && after
                    == E2EAddressFields(
                        sidebarText: start, sidebarNotSecure: false, topTabsText: before.topTabsText,
                        topTabsNotSecure: false),
            "before: \(before) under: \(under) after: \(after)")
    }
}

/// The certificate error page takes the keyboard as it comes up, so Return presses Go back; with the keyboard in the
/// command bar's field, Return there still goes to the typed address.
struct CertificateReturnTest: E2ETest {
    let name = "cert.return"

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        guard let bars = run.app as? any E2ECommandBarApp & E2EMenuApp else {
            throw E2EError("the app has no command bar")
        }
        _ = try E2ELoopback.runningWithCertificate()
        let page = try await AuthTests.openWindow(run, challenges)
        let (keyboard, back) = try await run.step("press Return on the page", timeout: E2ETimeouts.firstLoad) {
            try await AuthTests.loadBadCertificate(app, in: page, besides: page)
            let keyboard = try await E2EWaits.until { try app.certificatePageHasKeyboard(besides: page) }
            try app.pressReturn(in: page)
            _ = try await E2EWaits.until { try app.certificateErrorPage(besides: page) == nil }
            _ = try await E2EWaits.until(page, "document.title === 'Auth start'")
            return (keyboard, try await page.string("location.href"))
        }
        let typed = AuthTests.startURL.absoluteString + "?typed"
        let (barKeyboard, pageKeyboard, landed, after) = try await run.step(
            "press Return in the command bar", timeout: E2ETimeouts.firstLoad
        ) {
            try await AuthTests.loadBadCertificate(app, in: page, besides: page)
            _ = try await E2EWaits.until { try app.certificatePageHasKeyboard(besides: page) }
            try bars.chooseMenuItem(key: "l", modifiers: .command, in: page)
            let bar = try bars.commandBar(of: page)
            let opened = try await E2EWaits.until { bar.isShown && bar.hasKeyboard }
            let onPage = try app.certificatePageHasKeyboard(besides: page)
            try bar.type(typed)
            try await bar.waitForResults()
            try bar.press(.enter)
            _ = try await E2EWaits.until(page, "location.search === '?typed'")
            return (opened, onPage, try await page.string("location.href"), try app.certificateErrorPage(besides: page))
        }
        run.check(
            name,
            passed: keyboard && back == AuthTests.startURL.absoluteString && barKeyboard && !pageKeyboard
                && landed == typed && after == nil,
            "page-keyboard=\(keyboard) return-went-to=\(back) bar-keyboard=\(barKeyboard) "
                + "page-kept-keyboard=\(pageKeyboard) bar-return-went-to=\(landed) page-after=\(after.map(\.title) ?? "none")"
        )
    }
}

/// In split view the certificate error page covers only the pane whose tab failed, follows that pane when its divider
/// moves, leaves the other pane usable (it takes focus and runs its page), and goes with the pane when its tab closes.
struct CertificateSplitTest: E2ETest {
    let name = "cert.split"

    func run(_ run: E2ERun) async throws {
        let (app, challenges) = try AuthTests.apps(run)
        guard let panes = run.app as? any E2EPanesApp & E2ESplitApp else { throw E2EError("the app has no panes") }
        _ = try E2ELoopback.runningWithCertificate()
        let page = try await AuthTests.openWindow(run, challenges)
        let other = try await run.step("open a second tab", timeout: E2ETimeouts.firstLoad) {
            let other = try run.app.openTab(at: AuthTests.startURL, besides: page, select: false)
            _ = try await other.waitForLoad(after: 0)
            return other
        }
        let (shown, covers, keyboard) = try await run.step(
            "fail the second pane's load", timeout: E2ETimeouts.firstLoad
        ) {
            let shown = try panes.showPanes([page, other], focused: page, fractions: nil)
            try await AuthTests.loadBadCertificate(app, in: other, besides: page)
            return (shown, try app.certificateCovers(besides: page), try app.certificatePageHasKeyboard(besides: page))
        }
        let (moved, clickedIn, usable) = try await run.step(
            "move the divider, click into the page, then use the other pane", timeout: E2ETimeouts.step
        ) {
            try panes.dragPaneDivider(0, to: 0.35, besides: page)
            var moved = try app.certificateCovers(besides: page)
            _ = try await E2EWaits.until {
                moved = try app.certificateCovers(besides: page)
                return moved.last??.frame == moved.last??.paneFrame
            }
            // A click on the certificate page focuses its pane and gives the page the keyboard.
            try panes.clickPane(at: 1, besides: page)
            let clickedIn = try await E2EWaits.until {
                try panes.panes(besides: page).focusedIndex == 1 && app.certificatePageHasKeyboard(besides: page)
            }
            try panes.clickPane(at: 0, besides: page)
            let focused = try await E2EWaits.until {
                try panes.panes(besides: page).focusedIndex == 0 && !app.certificatePageHasKeyboard(besides: page)
            }
            let runs = try await page.evaluate("1 + 1") as? Int == 2
            let stillShown = try app.certificateErrorPage(besides: page) != nil
            return (moved, clickedIn && stillShown, focused && runs)
        }
        let (closed, after) = try await run.step("close the failed pane's tab", timeout: E2ETimeouts.step) {
            let closed = try await run.app.closeTab(other)
            _ = try await E2EWaits.until { try app.certificateCovers(besides: page).allSatisfy { $0 == nil } }
            return (closed, try app.certificateCovers(besides: page))
        }
        func onlySecondPane(_ list: [E2ECertificateCover?]) -> Bool {
            list.count == 2 && list[0] == nil && list[1].map { $0.frame == $0.paneFrame } == true
        }
        run.check(
            name,
            passed: shown && onlySecondPane(covers) && !keyboard && onlySecondPane(moved) && moved != covers
                && clickedIn && usable && closed && after == [nil],
            "shown=\(shown) covers=\(covers.map { $0?.description ?? "none" }) page-keyboard=\(keyboard) "
                + "after-drag=\(moved.map { $0?.description ?? "none" }) click-focuses-its-pane=\(clickedIn) "
                + "other-pane-usable=\(usable) "
                + "closed=\(closed) after-close=\(after.map { $0?.description ?? "none" })")
    }
}
