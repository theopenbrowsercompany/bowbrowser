import BowCore
import WebKit

// The tab's `EngineTabState`, read from the web view by key value observation and pushed as
// `TabEvent.stateChanged` whenever it changes.

extension WebKitTab {
    /// Observes the web view's address, title, loading and history state. WebKit reports them on the main thread.
    func observeState(of webView: WKWebView) {
        // WebKit's `url` moves to a navigation's address as it starts, just before it calls the navigation
        // delegate, and does not always move back when the navigation is stopped; the tab reports the committed
        // address. So a change is read on the next main thread task, once the delegate call has said whether a
        // navigation is provisional, and taken only when none is and the history's current entry agrees: what is
        // left is a same document change (a fragment, `history.pushState`). A commit sets the address itself.
        observations.append(
            webView.observe(\.url) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.webView === webView, !self.navigationEvents.isProvisional,
                            let url = webView.url, url == webView.backForwardList.currentItem?.url
                        else { return }
                        self.committedURL = url
                        self.refreshState()
                    }
                }
            })
        observations.append(webView.observe(\.title) { [weak self] _, _ in self?.stateDidChange() })
        observations.append(webView.observe(\.isLoading) { [weak self] _, _ in self?.stateDidChange() })
        observations.append(webView.observe(\.canGoBack) { [weak self] _, _ in self?.stateDidChange() })
        observations.append(webView.observe(\.canGoForward) { [weak self] _, _ in self?.stateDidChange() })
    }

    nonisolated private func stateDidChange() {
        MainActor.assumeIsolated { refreshState() }
    }

    /// Reads the state from the web view and sends `stateChanged` when it differs from the last one sent.
    func refreshState() {
        guard let webView else { return }
        var next = state
        next.url = committedURL
        next.title = webView.title ?? ""
        next.isLoading = webView.isLoading
        next.canGoBack = webView.canGoBack
        next.canGoForward = webView.canGoForward
        guard next != state else { return }
        state = next
        send(.stateChanged(next))
    }
}
