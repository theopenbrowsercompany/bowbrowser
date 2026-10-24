import BowCore
import Foundation
import WebKit

/// Unloading a tab to free its page, and restoring a new tab from the session the unloaded one kept.
///
/// The session is WebKit's public `interactionState`, which on macOS is `Data` (the W1 spike measured the same bytes
/// as the private `_sessionStateData`): the back and forward list with each entry's scroll position. WebKit writes
/// the scroll position into the current entry a moment after a scroll, so a page unloaded right after a scroll may
/// come back at the position before it.
extension WebKitTab {
    /// Saves the page's session, releases the web view (a navigation in progress fails as aborted first) and ends
    /// the tab with `TabEvent.unloaded`. False, with nothing changed, once the tab is closed.
    ///
    /// The page's beforeunload handler does not run: WebKit has no public way to run it, as with `close()`, so a
    /// page never keeps the tab loaded.
    func unload() async -> Bool {
        guard !isClosed, let webView else { return false }
        if webView.isLoading {
            // A session saved during a load holds the address being loaded, and WebKit's restore loads that one
            // rather than the entry the tab was on. Stop first and wait until WebKit has dropped it.
            stop()
            await Self.loadingStopped(webView, timeout: .seconds(2))
            // The tab may have closed or unloaded meanwhile.
            guard !isClosed, self.webView === webView else { return false }
        }
        let saved = webView.interactionState as? Data
        releaseWebView()
        end(.unloaded(sessionState: saved))
        return true
    }

    /// Returns once `webView` reports it is not loading, or after `timeout`.
    private static func loadingStopped(_ webView: WKWebView, timeout: Duration) async {
        guard webView.isLoading else { return }
        let done = AsyncStream<Void>.makeStream()
        let observation = webView.observe(\.isLoading) { webView, _ in
            if !webView.isLoading { done.continuation.yield() }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            done.continuation.yield()
        }
        if webView.isLoading {
            for await _ in done.stream { break }
        }
        timer.cancel()
        observation.invalidate()
        done.continuation.finish()
    }

    /// Hands `sessionState` to the tab's fresh web view, which then goes to the entry it was on with its back and
    /// forward lists. False when the tab has a page already, or the web view could not read the state (it then has
    /// no current entry), and the caller loads the address instead.
    func restore(_ sessionState: Data) -> Bool {
        guard let webView, webView.backForwardList.currentItem == nil else { return false }
        webView.interactionState = sessionState
        return webView.backForwardList.currentItem != nil
    }
}
