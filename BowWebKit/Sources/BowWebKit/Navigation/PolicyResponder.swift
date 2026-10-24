import BowCore
import Foundation
import WebKit

/// Asks the app's `EngineTabDelegate.tab(_:decidePolicyFor:)` about every main frame navigation, redirects
/// included, and answers WebKit with it. Navigations of other frames and of new windows are not the app's question
/// here and go on to the next responder.
///
/// A navigation the app cancels never starts in WebKit, so it sends no event; a redirect the app cancels ends the
/// navigation it belongs to, which WebKit reports as a failure (aborted).
@MainActor
final class PolicyResponder: NavigationResponder {
    func decidePolicy(for action: WKNavigationAction, in tab: WebKitTab) -> WKNavigationActionPolicy? {
        guard action.targetFrame?.isMainFrame == true, let url = action.request.url else { return nil }
        var navigation: EngineNavigation
        if tab.navigationEvents.isProvisional, tab.isRedirect(action), let current = tab.navigationEvents.current {
            // A redirect keeps the transition and gesture of the navigation it belongs to.
            navigation = current
            navigation.url = url
            navigation.isRedirect = true
        } else {
            navigation = EngineNavigation(
                url: url, transition: NavigationTransition(action.navigationType, isAppLoad: tab.takeAppLoad(url)),
                isUserGesture: Self.isUserGesture(action))
        }
        let isRedirect = navigation.isRedirect
        let policy = tab.delegate?.tab(tab, decidePolicyFor: navigation) ?? .allow
        guard policy == .allow else { return .cancel }
        if !isRedirect { tab.navigationEvents.allow(navigation) }
        return .allow
    }

    /// WebKit has no public user gesture flag on a navigation action: a link activation or a form submission is the
    /// person's (inference; script navigations read as no gesture).
    static func isUserGesture(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated || action.navigationType == .formSubmitted
    }
}
