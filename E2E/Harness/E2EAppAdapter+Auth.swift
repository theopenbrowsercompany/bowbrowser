import AppKit
import BowCore

// The sign in and certificate error area of the adapter: E2EAuthApp over the window's AuthSheetFeature, the sheet it
// puts on the window (and a popup panel's, over the panel's SignInSheets), and CertificateErrorFeature's pages over the
// panes. Both are answered by pressing their own buttons as a person does, so the press runs the same action the
// button runs for a click, and Return goes through the window's own key dispatch.

extension E2ETestApp: E2EAuthApp {
    func signInSheet(besides page: any E2EPage) throws -> E2ESignInSheet? {
        try adapter.requireActive(token, "read the sign in sheet")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sheet = controller.feature(AuthSheetFeature.self)?.sheet else { return nil }
        return Self.describe(sheet, on: controller.window)
    }

    func signInWaits(for page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the sign in requests")
        let tabPage = try E2EAppAdapter.tabPage(page)
        return tabPage.controller.feature(AuthSheetFeature.self)?.hasRequest(for: tabPage.tab) ?? false
    }

    func signInIdle(besides page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the sign in requests")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(AuthSheetFeature.self) else { return false }
        return feature.isIdle && controller.window?.attachedSheet == nil
    }

    func answerSignInSheet(besides page: any E2EPage, user: String?, password: String?) throws {
        try adapter.requireActive(token, "answer the sign in sheet")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sheet = controller.feature(AuthSheetFeature.self)?.sheet else {
            throw E2EError("no sign in sheet is up")
        }
        try Self.press(sheet, user: user, password: password)
    }

    func certificateErrorPage(besides page: any E2EPage) throws -> E2ECertificateErrorPage? {
        try adapter.requireActive(token, "read the certificate error page")
        guard let view = try Self.shownErrorView(besides: page) else { return nil }
        return E2ECertificateErrorPage(
            title: view.titleLabel.stringValue, message: view.messageLabel.stringValue,
            detail: view.detailLabel.stringValue,
            buttons: E2EAppAdapter.views(in: view, NSButton.self).map(\.title))
    }

    func pressCertificateGoBack(besides page: any E2EPage) throws {
        try adapter.requireActive(token, "press Go back")
        guard let view = try Self.shownErrorView(besides: page) else {
            throw E2EError("no certificate error page shows")
        }
        view.goBackButton.performClick(nil)
    }

    func certificateCovers(besides page: any E2EPage) throws -> [E2ECertificateCover?] {
        try adapter.requireActive(token, "read the certificate error pages")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let views = controller.feature(CertificateErrorFeature.self)?.errorViews ?? []
        let area = controller.pageArea
        area.layoutSubtreeIfNeeded()
        return controller.paneViews.enumerated().map { index, pane in
            guard index < views.count, !views[index].isHiddenOrHasHiddenAncestor else { return nil }
            return E2ECertificateCover(
                frame: views[index].convert(views[index].bounds, to: area),
                paneFrame: pane.convert(pane.bounds, to: area))
        }
    }

    func certificatePageHasKeyboard(besides page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the keyboard")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let views = controller.feature(CertificateErrorFeature.self)?.errorViews ?? []
        guard let responder = controller.window?.firstResponder else { return false }
        return views.contains { $0 === responder }
    }

    func pressReturn(in page: any E2EPage) throws {
        try adapter.requireActive(token, "press Return")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let window = controller.window else { throw E2EError("the page has no window") }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            else { throw E2EError("cannot make a Return key event") }
            window.sendEvent(event)
        }
    }

    func addressFields(of page: any E2EPage) throws -> E2EAddressFields {
        try adapter.requireActive(token, "read the URL fields")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sidebar = controller.feature(SidebarFeature.self)?.sidebar.accessory(URLField.self)?.field,
            let topTabs = controller.feature(TopTabsLayoutFeature.self)?.urlField
        else { throw E2EError("the window has no URL fields") }
        return E2EAddressFields(
            sidebarText: sidebar.text, sidebarNotSecure: sidebar.isNotSecure, topTabsText: topTabs.text,
            topTabsNotSecure: topTabs.isNotSecure)
    }

    func recordPanelChallenges(besides page: any E2EPage) throws -> any E2EAuthRecording {
        try adapter.requireActive(token, "record the popup panel's challenges")
        guard let panel = try Self.newestPanel(besides: page) else { throw E2EError("no popup panel is open") }
        let recorder = E2EPanelChallengeRecorder(panel: panel)
        // Tabs hold their delegate weakly; the test holds the recorder too, and lets go of it when it ends.
        E2EPanelChallengeRecorder.recorders = E2EPanelChallengeRecorder.recorders.filter { !$0.tabClosed }
        E2EPanelChallengeRecorder.recorders.append(recorder)
        panel.tab.delegate = recorder
        return recorder
    }

    func panelSignInSheet(besides page: any E2EPage) throws -> E2ESignInSheet? {
        try adapter.requireActive(token, "read the popup panel's sign in sheet")
        guard let panel = try Self.newestPanel(besides: page), let sheet = panel.signIn.sheet else { return nil }
        return Self.describe(sheet, on: panel.window)
    }

    func answerPanelSignInSheet(besides page: any E2EPage, user: String?, password: String?) throws {
        try adapter.requireActive(token, "answer the popup panel's sign in sheet")
        guard let panel = try Self.newestPanel(besides: page), let sheet = panel.signIn.sheet else {
            throw E2EError("no popup panel sign in sheet is up")
        }
        try Self.press(sheet, user: user, password: password)
    }

    // MARK: Helpers

    /// The first certificate error page shown over a pane of `page`'s window, leading to trailing.
    private static func shownErrorView(besides page: any E2EPage) throws -> CertificateErrorView? {
        let controller = try E2EAppAdapter.tabPage(page).controller
        let views = controller.feature(CertificateErrorFeature.self)?.errorViews ?? []
        return views.first { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func newestPanel(besides page: any E2EPage) throws -> PopupPanel? {
        let controller = try E2EAppAdapter.tabPage(page).controller
        return (controller.window?.childWindows ?? []).compactMap { $0.delegate as? PopupPanel }.last
    }

    private static func describe(_ sheet: SignInSheets.Sheet, on window: NSWindow?) -> E2ESignInSheet {
        let alert = sheet.alert
        return E2ESignInSheet(
            title: alert.messageText, message: alert.informativeText, buttons: alert.buttons.map(\.title),
            defaultButton: alert.window.defaultButtonCell?.title ?? "",
            fieldsReady: sheet.user.stringValue.isEmpty && sheet.password.stringValue.isEmpty,
            isAttached: window != nil && alert.window.sheetParent === window,
            offScreen: [window, alert.window].allSatisfy { window in
                guard let frame = window?.frame else { return true }
                return !NSScreen.screens.contains { $0.frame.intersects(frame) }
            })
    }

    /// Types `user` and `password` into `sheet` and presses Sign In, or presses Cancel when `user` is nil.
    private static func press(_ sheet: SignInSheets.Sheet, user: String?, password: String?) throws {
        let buttons = sheet.alert.buttons
        if let user {
            sheet.user.stringValue = user
            sheet.password.stringValue = password ?? ""
            guard let signIn = buttons.first, signIn.title == SignInSheets.signInTitle else {
                throw E2EError("the sheet has no \(SignInSheets.signInTitle) button")
            }
            signIn.performClick(nil)
        } else {
            guard let cancel = buttons.dropFirst().first, cancel.title == SignInSheets.cancelTitle else {
                throw E2EError("the sheet has no \(SignInSheets.cancelTitle) button")
            }
            cancel.performClick(nil)
        }
    }
}

/// A popup panel page's delegate while a test records its sign in questions: writes each down, hands it to the panel,
/// which answers it, and writes down the panel's answer. Every other hook goes to the panel unchanged.
@MainActor
final class E2EPanelChallengeRecorder: EngineTabDelegate, E2EAuthRecording {
    /// The recorders whose panel page is still open, held here since tabs hold their delegate weakly.
    static var recorders: [E2EPanelChallengeRecorder] = []

    private weak var panel: PopupPanel?
    private(set) var auth: [E2EAuthQuestion] = []
    /// The panel's page has closed (or unloaded).
    private(set) var tabClosed = false

    init(panel: PopupPanel) {
        self.panel = panel
    }

    func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials? {
        let index = auth.count
        auth.append(
            E2EAuthQuestion(
                host: challenge.host, port: challenge.port, realm: challenge.realm, scheme: challenge.scheme,
                isProxy: challenge.isProxy, answeredUser: nil, answered: false))
        let credentials = await panel?.tab(tab, answer: challenge)
        auth[index].answeredUser = credentials?.user
        auth[index].answered = true
        return credentials
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        panel?.tab(tab, didReceive: event)
        if event == .closed || event == .unloaded { tabClosed = true }
    }

    func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer {
        await panel?.tab(tab, runDialog: dialog) ?? .cancelled
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        panel?.tab(tab, decidePolicyFor: navigation) ?? .allow
    }
}
