import AppKit
import BowCore

// The challenges area of the adapter: E2EChallengesApp over the window controller. A recorder placed in front of the
// page's tab writes down each sign in and certificate question, hands it to the window, which asks its features,
// and writes down the window's answer. Every other hook goes to the window unchanged.

extension E2ETestApp: E2EChallengesApp {
    func recordChallenges(of page: any E2EPage) throws {
        try adapter.requireActive(token, "record challenges")
        let page = try E2EAppAdapter.tabPage(page)
        E2EChallengeRecorder.recorders = E2EChallengeRecorder.recorders.filter { !$0.value.tabClosed }
        let recorder = E2EChallengeRecorder(window: page.controller)
        E2EChallengeRecorder.recorders[page.tab.tabID] = recorder
        page.tab.delegate = recorder
    }

    func authChallenges(of page: any E2EPage) throws -> [E2EAuthQuestion] {
        try adapter.requireActive(token, "read sign in questions")
        return try E2EChallengeRecorder.recorder(of: page).auth
    }

    func certificateErrors(of page: any E2EPage) throws -> [E2ECertificateQuestion] {
        try adapter.requireActive(token, "read certificate questions")
        return try E2EChallengeRecorder.recorder(of: page).certificates
    }
}

/// A tab's delegate while a test records its challenges. Answers nothing itself: the window answers everything.
/// It stays tied to the window the tab was in when recording began, so a test that records must not move the tab
/// to another window (attaching it there makes that window its delegate again, which ends the recording).
@MainActor
final class E2EChallengeRecorder: EngineTabDelegate {
    /// Each recorded tab's recorder, held here since tabs hold their delegate weakly. A closed tab's recorder stays
    /// until the next `recordChallenges`, so a test can still read how a question was answered when its tab closed
    /// (the window answers it as the tab goes).
    static var recorders: [TabID: E2EChallengeRecorder] = [:]

    static func recorder(of page: any E2EPage) throws -> E2EChallengeRecorder {
        let page = try E2EAppAdapter.tabPage(page)
        guard let recorder = recorders[page.tab.tabID] else { throw E2EError("the page's challenges are not recorded") }
        return recorder
    }

    private weak var window: BrowserWindowController?
    private(set) var auth: [E2EAuthQuestion] = []
    private(set) var certificates: [E2ECertificateQuestion] = []
    /// The tab has closed (or unloaded).
    private(set) var tabClosed = false

    init(window: BrowserWindowController) {
        self.window = window
    }

    func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials? {
        let index = auth.count
        auth.append(
            E2EAuthQuestion(
                host: challenge.host, port: challenge.port, realm: challenge.realm, scheme: challenge.scheme,
                isProxy: challenge.isProxy, answeredUser: nil, answered: false))
        let credentials = await window?.tab(tab, answer: challenge)
        auth[index].answeredUser = credentials?.user
        auth[index].answered = true
        return credentials
    }

    func tab(_ tab: any EngineTab, decideCertificateError error: CertificateError) async -> CertificateErrorDecision {
        let index = certificates.count
        certificates.append(E2ECertificateQuestion(url: error.url, reason: "\(error.reason)", proceeded: nil))
        let decision = await window?.tab(tab, decideCertificateError: error) ?? .cancel
        certificates[index].proceeded = decision == .proceed
        return decision
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        window?.tab(tab, didReceive: event)
        if event == .closed || event == .unloaded { tabClosed = true }
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        window?.tab(tab, decidePolicyFor: navigation) ?? .allow
    }

    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        await window?.tab(tab, decidePermission: request) ?? .dismiss
    }

    func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision {
        window?.tab(tab, decidePopup: request) ?? .block
    }

    func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest) {
        if let window {
            window.tab(tab, didOpenPopup: newTab, request: request)
        } else {
            Task { _ = await newTab.close() }
        }
    }

    func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool {
        window?.tab(tab, handleKeyBeforePage: event) ?? false
    }

    func tab(_ tab: any EngineTab, decideContextMenu request: ContextMenuRequest) -> ContextMenuDecision {
        window?.tab(tab, decideContextMenu: request) ?? .engineDefault
    }

    func tab(
        _ tab: any EngineTab, runContextMenuCommand command: ContextMenuCommand, request: ContextMenuRequest
    ) -> Bool {
        window?.tab(tab, runContextMenuCommand: command, request: request) ?? false
    }
}
