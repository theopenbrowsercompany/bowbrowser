import BowCore
import Foundation
import WebKit

/// A modified click on a link that opens in its own frame: Command or the middle button (a background tab), Command
/// Shift (a foreground tab) or Shift (a window, which Bow's rules answer with a Peek). WebKit loads such a click in
/// the same tab and never asks `createWebViewWith`, so this asks the app's `decidePopup` as Chromium's
/// `OnOpenURLFromTab` does on CEF, and answers as Bow on CEF does (`WebKitTab.openLinkInNewTab`): a tab, panel or Peek
/// decision cancels the click here and opens the link in a new tab of the profile, a block cancels it, and a
/// `.window` decision (or nobody deciding) lets the link load here, as before.
///
/// Left to the other responders, as today: a plain click, a click of a link in another frame (one inside a frame,
/// or whose target names one), a form submission, a server redirect of a navigation already decided, a link to
/// download (its `download` attribute, the downloads responder's) and a link to anything but http(s).
@MainActor
final class LinkDispositionResponder: NavigationResponder {
    func decidePolicy(for action: WKNavigationAction, in tab: WebKitTab) -> WKNavigationActionPolicy? {
        guard Self.asksForNewTab(action, in: tab) else { return nil }
        return tab.openLinkInNewTab(action) ? .cancel : nil
    }

    /// Whether `action` is a main frame link click with a modifier that asks for a new tab or window.
    static func asksForNewTab(_ action: WKNavigationAction, in tab: WebKitTab) -> Bool {
        guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
            !action.shouldPerformDownload, !tab.isRedirect(action),
            let scheme = action.request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        return action.modifierFlags.contains(.command) || action.modifierFlags.contains(.shift)
            || PopupRequest.eventButtonNumber(webKitButtons: action.buttonNumber) == 2
    }
}
