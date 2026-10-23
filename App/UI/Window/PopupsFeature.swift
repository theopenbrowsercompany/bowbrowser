import AppKit
import BowCore

/// Where the pages a window's tabs open go: answers the popup decision with `PopupPolicy` and takes each page it
/// decided as a tab into the sidebar through `BrowserWindowController.adoptTab`, right after its opener (or at the top
/// of today when the opener is pinned or a Favorite), shown or left in the background as the policy says.
///
/// A link meant for a new tab and a script's `window.open` after a click arrive as popups with `window.opener` kept; a
/// Cmd-click, Cmd-Shift-click, Shift-click or middle click on a link arrives the same way without an opener. A sized
/// popup or an identity provider's sign in page is answered `.popupPanel`, which `PopupPanelFeature` takes, and a page
/// that opens one without a click opens nothing. A Shift-click is answered `.peek` (under the Peek settings), which
/// `PeekFeature` takes.
@MainActor
final class PopupsFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func decidePopup(_ request: PopupRequest, from tab: any EngineTab) -> PopupDecision? {
        guard let window else { return nil }
        return PopupPolicy.outcome(for: request, openerZone: Self.zone(of: tab, in: window), peek: peek(in: window))
            .decision
    }

    /// The Peek settings and whether the window shows a Peek, which decide a Shift-click (`PeekFeature` takes a Peek).
    private func peek(in window: BrowserWindowController) -> PeekContext {
        window.feature(PeekFeature.self)?.context ?? PeekContext(settings: AppSettings.peekSettings)
    }

    func didOpenPopup(_ newTab: any EngineTab, from tab: any EngineTab, request: PopupRequest) -> Bool {
        guard let window else { return false }
        // The same pure policy answered the decision a moment ago, so it gives the same outcome now.
        let outcome = PopupPolicy.outcome(
            for: request, openerZone: Self.zone(of: tab, in: window), peek: peek(in: window))
        let select: Bool
        switch outcome.decision {
        case .foregroundTab: select = true
        case .backgroundTab: select = false
        // PopupPanelFeature takes a panel's page, PeekFeature a Peek's.
        case .popupPanel, .peek, .window, .block: return false
        }
        return window.adoptTab(
            newTab, after: tab, placement: outcome.placement ?? PopupPolicy.todayPlacement, select: select,
            url: request.targetURL)
    }

    /// Where `tab`, one of `window`'s tabs, sits in the sidebar.
    private static func zone(of tab: any EngineTab, in window: BrowserWindowController) -> PopupOpenerZone {
        guard let item = window.modelID(of: tab).flatMap({ window.sidebarItemID(for: $0) }) else { return .today }
        let graph = window.store.graph
        if graph.isInFavorites(item) { return .favorite }
        if graph.isPinned(item) { return .pinned }
        return .today
    }
}
