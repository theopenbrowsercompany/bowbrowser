import BowCore
import Foundation
import WebKit

/// One concern of a tab's navigations (the app's policy, Bow's navigation events, and later downloads, sign in and
/// certificates), so the tab's one `WKNavigationDelegate` stays a switchboard. The tab asks its responders in the
/// order of `NavigationResponders.all`: for a policy, the first that answers wins and the rest are not asked; every
/// navigation callback reaches every responder, in that order. Every method has a default that does nothing.
///
/// The design follows DuckDuckGo's navigation responder chain for WebKit; no code is taken from it.
@MainActor
protocol NavigationResponder: AnyObject {
    /// The answer for a navigation action WebKit asks about (any frame), or nil to leave it to the next responder.
    func decidePolicy(for action: WKNavigationAction, in tab: WebKitTab) -> WKNavigationActionPolicy?
    /// The answer for a response WebKit asks about (any frame), or nil to leave it to the next responder.
    func decidePolicy(for response: WKNavigationResponse, in tab: WebKitTab) -> WKNavigationResponsePolicy?

    /// The main frame's navigation callbacks, as WebKit makes them.
    func didStart(_ key: NavigationKey?, url: URL, in tab: WebKitTab)
    func didRedirect(_ key: NavigationKey?, url: URL, in tab: WebKitTab)
    func didCommit(_ key: NavigationKey?, url: URL, in tab: WebKitTab)
    func didFinish(_ key: NavigationKey?, in tab: WebKitTab)
    /// `isProvisional` is true for a failure before commit.
    func didFail(_ key: NavigationKey?, error: any Error, isProvisional: Bool, in tab: WebKitTab)

    /// A sign in or server trust question of any load of the page. True takes it: the responder then calls
    /// `completionHandler` exactly once, whatever happens to the tab meanwhile, and no later responder is asked.
    /// When no responder takes it, WebKit handles it as it would with no delegate.
    func didReceive(
        _ challenge: URLAuthenticationChallenge, in tab: WebKitTab,
        completionHandler: @escaping ChallengeHandler
    ) -> Bool
}

/// WebKit's answer to an authentication challenge.
typealias ChallengeHandler = @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

extension NavigationResponder {
    func decidePolicy(for action: WKNavigationAction, in tab: WebKitTab) -> WKNavigationActionPolicy? { nil }
    func decidePolicy(for response: WKNavigationResponse, in tab: WebKitTab) -> WKNavigationResponsePolicy? { nil }
    func didStart(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {}
    func didRedirect(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {}
    func didCommit(_ key: NavigationKey?, url: URL, in tab: WebKitTab) {}
    func didFinish(_ key: NavigationKey?, in tab: WebKitTab) {}
    func didFail(_ key: NavigationKey?, error: any Error, isProvisional: Bool, in tab: WebKitTab) {}
    func didReceive(
        _ challenge: URLAuthenticationChallenge, in tab: WebKitTab,
        completionHandler: @escaping ChallengeHandler
    ) -> Bool { false }
}

/// The fixed, ordered list of a tab's navigation responders: the one place that says who is asked first. A new
/// concern is a new responder file plus one line here.
@MainActor
enum NavigationResponders {
    static func all() -> [any NavigationResponder] {
        [
            // The app's policy first: a navigation it cancels reaches no other responder.
            PolicyResponder(),
            // A new document ends the find in progress before the app hears of the commit.
            FindResponder(),
            // HTTP sign in and server trust, which only this responder answers.
            ChallengeResponder(),
            // Last, so the other responders have seen a callback before the app hears of it.
            NavigationEventResponder(),
        ]
    }
}
