import Foundation

/// When the page area shows a placeholder card for an unloaded tab that loads again, and what the card says. The card
/// stands in for the page from the moment the tab is shown until its page has loaded or failed to.
public enum UnloadPlaceholder {
    /// Whether a tab shown again shows the card: it was unloaded and is loading again, and it is the only pane, so the
    /// card never covers another pane's live page.
    public static func shows(wasUnloaded: Bool, paneCount: Int) -> Bool {
        wasUnloaded && paneCount == 1
    }

    /// Whether `event` from the tab loading again ends the card: its page finished or failed to load, its render
    /// process ended, or the tab closed or unloaded again. Anything earlier (the start, a redirect, the commit, title
    /// and icon changes) keeps it.
    public static func ends(on event: TabEvent) -> Bool {
        switch event {
        case .didFinish, .didFail, .renderProcessGone, .unloaded, .closed: true
        case .stateChanged, .didStartNavigation, .didRedirect, .didCommit, .popupRequested, .fullscreenChanged,
            .findResult, .statusTextChanged:
            false
        }
    }

    /// The card's title: the page title the tab had, or its address's host when it had none, or the whole address.
    public static func title(saved: String?, url: URL?) -> String {
        if let saved = saved?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty { return saved }
        if let host = url?.host(), !host.isEmpty { return host }
        return url?.absoluteString ?? ""
    }
}
