import AppKit
import BowCore

/// The sign in sheet: a site (or proxy) asking for a user name and password comes up as a sheet on the window while
/// the window shows the tab that asked, as Chrome's login prompt does (`SignInPolicy` holds the rules). It names who
/// asks, has a user name and a password field, Sign In (the default button) and Cancel. Sign In answers with what was
/// typed and the load goes on (a wrong password makes the server ask again); Cancel answers cancelled and the page
/// shows the site's own 401 page. A request from a tab the window does not show waits for its tab. Switching tabs takes
/// the sheet down and brings it back with its tab; a new navigation, a crash, closing the tab or the window, and
/// quitting cancel it. Nothing is saved: passwords stay with the engine's own sign in cache for the session.
/// The sheets themselves are `SignInSheets`, which a popup panel uses for its own page too.
@MainActor
final class AuthSheetFeature: NSResponder, BrowserWindowFeature {
    static let signInTitle = SignInSheets.signInTitle
    static let cancelTitle = SignInSheets.cancelTitle

    private let sheets: SignInSheets

    /// The sheet on the window, if a request is up.
    var sheet: SignInSheets.Sheet? { sheets.sheet }

    init(window: BrowserWindowController) {
        sheets = SignInSheets(window: window.window)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Whether `tab` has a sign in request up or waiting for its tab to be shown.
    func hasRequest(for tab: any EngineTab) -> Bool {
        sheets.hasRequest(for: tab.tabID)
    }

    /// Whether no sign in request waits in this window.
    var isIdle: Bool { sheets.isIdle }

    func answer(_ challenge: AuthChallenge, for tab: any EngineTab) async -> AuthCredentials? {
        // Nil (Cancel, or the request went) leaves it to the features after this one, and with none it is cancelled.
        await sheets.answer(challenge, for: tab.tabID)
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        sheets.show(tab?.tabID)
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        // A request belongs to the load that asked: a new navigation leaves it, and a page whose render process
        // ended can no longer use the answer.
        switch event {
        case .didStartNavigation, .renderProcessGone: sheets.navigated(tab.tabID)
        default: break
        }
    }

    func tabDidClose(_ tab: any EngineTab) {
        sheets.closed(tab.tabID)
    }
}
