import AppKit
import BowCore

// The window hooks area of the adapter: E2EWindowHooksApp over the window controller. A test adopts popups through
// a delegate placed in front of the opener's tab, which answers the popup hooks the way a link handling feature will
// and hands every other hook to the window unchanged.

extension E2ETestApp: E2EWindowHooksApp {
    func adoptPopups(of page: any E2EPage) throws {
        try adapter.requireActive(token, "adopt popups")
        let page = try E2EAppAdapter.tabPage(page)
        let adopter = E2EPopupAdopter(opener: page, adapter: adapter, token: token)
        E2EPopupAdopter.adopters[page.tab.tabID] = adopter
        page.tab.delegate = adopter
    }

    func adoptedPages(of page: any E2EPage) throws -> [any E2EPage] {
        try E2EPopupAdopter.adopter(of: page).adopted
    }

    func popupModifiers(of page: any E2EPage) throws -> [E2EClickModifiers] {
        try E2EPopupAdopter.adopter(of: page).requests.map {
            E2EClickModifiers(command: $0.clickModifiers.command, shift: $0.clickModifiers.shift)
        }
    }

    func rowTitles(besides page: any E2EPage) throws -> [String] {
        try E2EAppAdapter.tabPage(page).controller.tabList.tabs.map(\.title)
    }
}

/// The opener tab's delegate while a test adopts its popups. The window stays the delegate of every other tab, and
/// of the adopted ones.
@MainActor
final class E2EPopupAdopter: EngineTabDelegate {
    /// Each opener's adopter, held here since tabs hold their delegate weakly. A test's adopters go with its tabs.
    static var adopters: [TabID: E2EPopupAdopter] = [:]

    static func adopter(of page: any E2EPage) throws -> E2EPopupAdopter {
        let page = try E2EAppAdapter.tabPage(page)
        guard let adopter = adopters[page.tab.tabID] else { throw E2EError("the page's popups are not adopted") }
        return adopter
    }

    private weak var window: BrowserWindowController?
    private unowned let adapter: E2EAppAdapter
    private let token: Int
    private(set) var requests: [PopupRequest] = []
    private(set) var adopted: [E2ETabPage] = []

    init(opener: E2ETabPage, adapter: E2EAppAdapter, token: Int) {
        window = opener.controller
        self.adapter = adapter
        self.token = token
    }

    func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision {
        requests.append(request)
        return .foregroundTab
    }

    func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest) {
        guard let window, (try? adapter.requireActive(token, "adopt a popup")) != nil,
            window.adoptTab(newTab, after: tab, placement: .afterOpener, select: true, url: request.targetURL)
        else {
            Task { _ = await newTab.close() }
            return
        }
        adopted.append(adapter.track(newTab, in: window, token: token))
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        window?.tab(tab, didReceive: event)
        if event == .closed { Self.adopters[tab.tabID] = nil }
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        window?.tab(tab, decidePolicyFor: navigation) ?? .allow
    }

    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        await window?.tab(tab, decidePermission: request) ?? .dismiss
    }

    func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool {
        window?.tab(tab, handleKeyBeforePage: event) ?? false
    }

    func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials? {
        await window?.tab(tab, answer: challenge)
    }

    func tab(_ tab: any EngineTab, decideCertificateError error: CertificateError) async -> CertificateErrorDecision {
        await window?.tab(tab, decideCertificateError: error) ?? .cancel
    }
}
