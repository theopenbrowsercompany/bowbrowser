import BowCore
import WebKit

// The page's web content process ending (a crash, a kill, a memory or CPU limit), sent as
// `TabEvent.renderProcessGone` with its reason. WebKit leaves the page blank and keeps its address; nothing reloads
// it until the app calls `reload()`, because a delegate that handles the termination turns WebKit's own reload off.

extension WebKitTab {
    /// Takes WebKit's private termination callback, which carries the reason. The tab answers it (it is in
    /// `privateCallbacks`), so WebKit calls it in place of the public `webViewWebContentProcessDidTerminate`.
    func observeProcessGone() {
        onProcessTerminated = { [weak self] reason in self?.processGone(ProcessGoneReason(reason)) }
    }

    /// The public callback, called only where WebKit dropped the private one: no reason.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard webView === self.webView else { return }
            processGone(.other)
        }
    }

    /// Ends the navigation in progress as aborted, reads the state the blank page left, and sends the event once
    /// per termination.
    func processGone(_ reason: ProcessGoneReason) {
        guard !isClosed, webView != nil else { return }
        send(navigationEvents.abort())
        refreshState()
        send(.renderProcessGone(reason))
    }
}
