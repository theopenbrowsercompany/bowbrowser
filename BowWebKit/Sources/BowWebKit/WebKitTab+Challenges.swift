import Foundation
import WebKit

// Authentication challenges (HTTP sign in, server trust) go through the tab's navigation responders; the one that
// takes a challenge answers it (see ChallengeResponder.swift).

extension WebKitTab {
    nonisolated func webView(
        _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        MainActor.assumeIsolated {
            // A released web view's late question: answer it, trusting and sending nothing.
            guard webView === self.webView else { return completionHandler(.cancelAuthenticationChallenge, nil) }
            for responder in responders {
                if responder.didReceive(challenge, in: self, completionHandler: completionHandler) { return }
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
