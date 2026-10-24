import BowCore
import WebKit

// Page fullscreen (the Fullscreen API's element fullscreen): `TabEvent.fullscreenChanged` from WebKit's public
// `fullscreenState`, read by key value observation, and `exitFullscreen()` through `closeAllMediaPresentations`.
// WebKit shows a fullscreen element in a window of its own, and only with element fullscreen turned on
// (`WKPreferences.isElementFullscreenEnabled`, off by default), which every tab's page has, as in Arc.

extension WebKitTab {
    /// Lets the page go fullscreen and observes it entering and leaving. Each web view gets its own tracker, so a
    /// replaced page starts out of fullscreen.
    func observeFullscreen(of webView: WKWebView) {
        // The web view's configuration is a copy, but it shares the page's live preferences object.
        webView.configuration.preferences.isElementFullscreenEnabled = true
        let tracker = FullscreenTracker()
        observations.append(
            webView.observe(\.fullscreenState) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, self.webView === webView else { return }
                    self.fullscreenStateDidChange(to: webView.fullscreenState, tracker)
                }
            })
    }

    /// Sends `fullscreenChanged` when `state` moves the page into or out of fullscreen.
    func fullscreenStateDidChange(to state: WKWebView.FullscreenState, _ tracker: FullscreenTracker) {
        guard let isFullscreen = tracker.take(state) else { return }
        send(.fullscreenChanged(isFullscreen))
    }

    /// Asks the page to leave fullscreen; `fullscreenChanged(false)` follows once WebKit has left it. Does nothing
    /// when the page is not fullscreen (and so leaves picture in picture alone) or the tab is closed.
    func exitFullscreen() {
        guard let webView, webView.fullscreenState != .notInFullscreen else { return }
        webView.closeAllMediaPresentations {}
    }
}

/// Turns WebKit's fullscreen states into Bow's fullscreen changes: in fullscreen is true and out of it is false,
/// the states between (entering, exiting) change nothing, and a change is reported once. So a page that starts
/// entering fullscreen and falls back out of it reports nothing.
@MainActor
final class FullscreenTracker {
    private(set) var isFullscreen = false

    /// The new fullscreen value when `state` changes it, or nil.
    func take(_ state: WKWebView.FullscreenState) -> Bool? {
        let next: Bool
        switch state {
        case .inFullscreen: next = true
        case .notInFullscreen: next = false
        case .enteringFullscreen, .exitingFullscreen: return nil
        @unknown default: return nil
        }
        guard next != isFullscreen else { return nil }
        isFullscreen = next
        return next
    }
}
