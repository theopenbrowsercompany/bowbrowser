import BowCore
import WebKit

// New pages the page opens (`window.open`, a link with a target) and pages that close themselves (`window.close()`).
//
// WebKit has no windows of its own, so every decision but `.block` makes the new page a tab of the opener's profile
// and hands it to the delegate's `didOpenPopup`, `.window` included (the contract's engine with no windows): the app
// shows it where it decided. The new tab's web view is built from the configuration WebKit passes, which is what
// keeps `window.opener`, and it is returned to WebKit synchronously, inside the call.

extension WebKitTab {
    nonisolated func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            openPopup(from: webView, configuration: configuration, action: navigationAction, features: windowFeatures)
        }
    }

    /// The page called `window.close()` and WebKit let it (a page a script opened, or one with no history to go back
    /// to): the tab closes as the page's own close.
    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard webView === self.webView else { return }
            Task { _ = await close(reason: .page) }
        }
    }

    /// The new page's web view, or nil when nothing opens: the request comes from a page the tab no longer shows, the
    /// tab has no delegate, the delegate blocks it, or the profile refuses new tabs because it is quitting (the popup
    /// tab is then born closed with `.quit` and never handed over). A tab the delegate closed while taking it opens
    /// nothing either.
    private func openPopup(
        from webView: WKWebView, configuration: WKWebViewConfiguration, action: WKNavigationAction,
        features: WKWindowFeatures
    ) -> WKWebView? {
        guard webView === self.webView, !isClosed, let delegate else { return nil }
        let request = PopupRequest(action, features: features)
        guard delegate.tab(self, decidePopup: request) != .block else { return nil }
        let popup = profile.createTab(configuration: configuration)
        guard !popup.isClosed else { return nil }
        // Before WebKit starts the new page's first navigation, so the app's delegate and policy cover it.
        delegate.tab(self, didOpenPopup: popup, request: request)
        return popup.webView
    }
}
