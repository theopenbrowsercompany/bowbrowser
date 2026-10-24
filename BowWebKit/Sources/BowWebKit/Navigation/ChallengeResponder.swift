import BowCore
import Foundation
import Security
import WebKit

/// Answers WebKit's authentication challenges with the app's answers: HTTP basic and digest sign in through
/// `EngineTabDelegate.tab(_:answer:)`, and a server certificate that fails to verify through
/// `tab(_:decideCertificateError:)`. Both kinds arrive through the same WebKit callback and are told apart by the
/// protection space's method; every other method (client certificates, NTLM, Negotiate) is left to WebKit.
///
/// Nothing is ever trusted or sent by default: a certificate that verifies is left to WebKit, one that does not
/// loads only when the app says `.proceed`, and credentials go only to the server that asked, only when the app
/// gives them. A tab that closed, or replaced its page, while the app was deciding gets a cancel instead.
@MainActor
final class ChallengeResponder: NavigationResponder {
    func didReceive(
        _ challenge: URLAuthenticationChallenge, in tab: WebKitTab,
        completionHandler: @escaping ChallengeHandler
    ) -> Bool {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust {
            guard let trust = challenge.protectionSpace.serverTrust else { return false }
            decideTrust(trust, of: challenge, in: tab, completionHandler: completionHandler)
            return true
        }
        guard let scheme = AuthChallenge.scheme(authenticationMethod: method) else { return false }
        let question = AuthChallenge(challenge, scheme: scheme, navigationURL: Self.navigationURL(of: tab))
        answer(question, in: tab, completionHandler: completionHandler)
        return true
    }

    /// The address the main frame is going to: the navigation in progress, else the page's address, which WebKit
    /// sets to a new load's address before it starts (a load may connect before WebKit reports its start).
    private static func navigationURL(of tab: WebKitTab) -> URL? {
        tab.navigationEvents.current?.url ?? tab.webView?.url
    }

    // MARK: Sign in

    /// Asks the app for credentials. Without an answer the load goes on with none, so the page shows the server's
    /// own 401 page, as the contract says; a stored credential is never used in its place.
    private func answer(
        _ question: AuthChallenge, in tab: WebKitTab, completionHandler: @escaping ChallengeHandler
    ) {
        let page = tab.webView
        Task { @MainActor [weak tab, weak page] in
            var credentials: AuthCredentials?
            if let tab, let delegate = tab.delegate {
                credentials = await delegate.tab(tab, answer: question)
            }
            guard let tab, let page, tab.webView === page else {
                return completionHandler(.cancelAuthenticationChallenge, nil)
            }
            guard let credentials else { return completionHandler(.useCredential, nil) }
            // Kept for the session, as Chromium keeps an answered realm: the page's other loads of the same realm
            // are not asked again, and nothing outlives the engine.
            completionHandler(
                .useCredential,
                URLCredential(user: credentials.user, password: credentials.password, persistence: .forSession))
        }
    }

    // MARK: Server trust

    /// A server and the certificate it showed.
    private struct TrustKey: Hashable {
        var host: String
        var port: Int
        var certificate: Data
    }

    /// The challenges of each certificate whose question is open, answered together when it is decided: the page's
    /// loads of one server (and WebKit's early connection to it) ask the person once.
    private var waiting: [TrustKey: [(trust: SecTrust, completionHandler: ChallengeHandler)]] = [:]
    /// The app's answers (true to proceed) since the last main frame navigation ended: WebKit verifies each new
    /// connection, and tries a refused one again, and those take the answer given without asking again. Forgotten
    /// when the navigation ends, so a later load asks again; what the person allowed is the app's to remember
    /// (`CertificateAllowances`), never the engine's.
    private var decided: [TrustKey: Bool] = [:]

    func didFinish(_ key: NavigationKey?, in tab: WebKitTab) {
        decided = [:]
    }

    func didFail(_ key: NavigationKey?, error: any Error, isProvisional: Bool, in tab: WebKitTab) {
        decided = [:]
    }

    /// Verifies the server's certificate off the main thread; one that verifies is left to WebKit, one that does
    /// not is the app's question, with the reason the verification gave.
    private func decideTrust(
        _ trust: SecTrust, of challenge: URLAuthenticationChallenge, in tab: WebKitTab,
        completionHandler: @escaping ChallengeHandler
    ) {
        let space = challenge.protectionSpace
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        let key = TrustKey(
            host: space.host, port: space.port, certificate: leaf.map { SecCertificateCopyData($0) as Data } ?? Data())
        if let proceed = decided[key] {
            // Refused: WebKit verifies it itself and fails the load with its certificate error.
            return proceed
                ? completionHandler(.useCredential, URLCredential(trust: trust))
                : completionHandler(.performDefaultHandling, nil)
        }
        guard waiting[key] == nil else { return waiting[key]?.append((trust, completionHandler)) ?? () }
        waiting[key] = [(trust, completionHandler)]

        let url = AuthChallenge.address(of: space, navigationURL: Self.navigationURL(of: tab))
        let page = tab.webView
        // The responder lives until every waiting challenge is answered, even when its tab is gone, so WebKit's
        // completion handlers are always called.
        let status = SecTrustEvaluateAsyncWithError(trust, DispatchQueue.main) { trust, trusted, error in
            MainActor.assumeIsolated {
                if trusted { return self.answer(key) { _ in (.performDefaultHandling, nil) } }
                var result = SecTrustResultType.invalid
                SecTrustGetTrustResult(trust, &result)
                let code = error.map { OSStatus(CFErrorGetCode($0)) } ?? errSecNotTrusted
                let question = CertificateError(url: url, reason: .init(trustResult: result, status: code))
                self.ask(question, key: key, in: tab, page: page)
            }
        }
        // Not started: WebKit verifies it itself and fails the load if it does not verify.
        if status != errSecSuccess { answer(key) { _ in (.performDefaultHandling, nil) } }
    }

    private func ask(_ question: CertificateError, key: TrustKey, in tab: WebKitTab?, page: WebKitWebView?) {
        Task { @MainActor [weak tab, weak page] in
            var decision = CertificateErrorDecision.cancel
            if let tab, let delegate = tab.delegate {
                decision = await delegate.tab(tab, decideCertificateError: question)
            }
            guard let tab, let page, tab.webView === page else {
                // The tab closed or replaced its page meanwhile: its loads are over, and nothing is trusted.
                return self.answer(key) { _ in (.cancelAuthenticationChallenge, nil) }
            }
            guard decision == .proceed else {
                self.decided[key] = false
                return self.answer(key) { _ in (.performDefaultHandling, nil) }
            }
            self.decided[key] = true
            self.answer(key) { trust in (.useCredential, URLCredential(trust: trust)) }
        }
    }

    /// Answers every challenge waiting on `key`, each with `disposition` of its own trust.
    private func answer(
        _ key: TrustKey, _ disposition: (SecTrust) -> (URLSession.AuthChallengeDisposition, URLCredential?)
    ) {
        for waiter in waiting.removeValue(forKey: key) ?? [] {
            let (answer, credential) = disposition(waiter.trust)
            waiter.completionHandler(answer, credential)
        }
    }
}
