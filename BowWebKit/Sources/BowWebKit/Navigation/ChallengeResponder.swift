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
/// gives them. A tab that closed, or replaced its page, while the app was deciding gets a cancel instead. As in
/// Chromium, only the main frame's certificate is the app's question: another load whose certificate fails is
/// refused unasked, unless the page's main frame went past the same certificate.
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

    /// A certificate question open with the app for one page, and the challenges waiting for its answer: the
    /// main frame's connections to one server (WebKit's early connection, a retry) ask the person once.
    private final class TrustQuestion {
        let key: TrustKey
        weak var page: WebKitWebView?
        var waiters: [(trust: SecTrust, completionHandler: ChallengeHandler)]

        init(key: TrustKey, page: WebKitWebView?, trust: SecTrust, completionHandler: @escaping ChallengeHandler) {
            self.key = key
            self.page = page
            waiters = [(trust, completionHandler)]
        }
    }

    private var questions: [TrustQuestion] = []
    /// The page the answers below were given for; any other page starts with none.
    private weak var answeredPage: WebKitWebView?
    /// The app's answers (true to proceed) during the main frame navigation in progress, which its later
    /// connections to the same server and certificate take without asking again. Forgotten when the navigation
    /// ends, so the next one asks again: what the person allowed is the app's to remember
    /// (`CertificateAllowances`), never the engine's.
    private var navigationAnswers: [TrustKey: Bool] = [:]
    /// The certificates the app let this page's main frame load past: the page's other loads from the same server
    /// and certificate (images, requests after it finished) are trusted with it, as Chromium trusts a page's
    /// subresources once a person went on. Every other load with a certificate that fails is refused unasked.
    private var pageAllowances: Set<TrustKey> = []

    func didFinish(_ key: NavigationKey?, in tab: WebKitTab) {
        navigationAnswers = [:]
    }

    func didFail(_ key: NavigationKey?, error: any Error, isProvisional: Bool, in tab: WebKitTab) {
        navigationAnswers = [:]
    }

    /// The main frame's address, when the challenge comes from its navigation to that server: a navigation is
    /// provisional, or the page is loading one that has not started yet. Nil for every other load.
    private static func mainFrameURL(of tab: WebKitTab, for space: URLProtectionSpace) -> URL? {
        let events = tab.navigationEvents
        guard events.isProvisional || (!events.isActive && tab.webView?.isLoading == true),
            let url = navigationURL(of: tab), url.scheme == "https",
            url.host?.lowercased() == space.host.lowercased(), (url.port ?? 443) == space.port
        else { return nil }
        return url
    }

    /// Verifies the main frame's server certificate off the main thread; one that verifies is left to WebKit, one
    /// that does not is the app's question, with the reason the verification gave. Other loads are WebKit's to
    /// verify, unless the page's main frame already went past the same certificate.
    private func decideTrust(
        _ trust: SecTrust, of challenge: URLAuthenticationChallenge, in tab: WebKitTab,
        completionHandler: @escaping ChallengeHandler
    ) {
        let space = challenge.protectionSpace
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        let key = TrustKey(
            host: space.host.lowercased(), port: space.port,
            certificate: leaf.map { SecCertificateCopyData($0) as Data } ?? Data())
        let page = tab.webView
        if answeredPage !== page {
            answeredPage = page
            navigationAnswers = [:]
            pageAllowances = []
        }
        guard let url = Self.mainFrameURL(of: tab, for: space) else {
            return pageAllowances.contains(key)
                ? completionHandler(.useCredential, URLCredential(trust: trust))
                : completionHandler(.performDefaultHandling, nil)
        }
        if let proceed = navigationAnswers[key] {
            // Refused: WebKit verifies it itself and fails the load with its certificate error.
            return proceed
                ? completionHandler(.useCredential, URLCredential(trust: trust))
                : completionHandler(.performDefaultHandling, nil)
        }
        if let open = questions.first(where: { $0.key == key && $0.page != nil && $0.page === page }) {
            return open.waiters.append((trust, completionHandler))
        }
        let question = TrustQuestion(key: key, page: page, trust: trust, completionHandler: completionHandler)
        questions.append(question)
        // The responder lives until every waiting challenge is answered, even when its tab is gone, so WebKit's
        // completion handlers are always called.
        let status = SecTrustEvaluateAsyncWithError(trust, DispatchQueue.main) { trust, trusted, error in
            MainActor.assumeIsolated {
                if trusted { return self.resolve(question) { _ in (.performDefaultHandling, nil) } }
                var result = SecTrustResultType.invalid
                SecTrustGetTrustResult(trust, &result)
                let code = error.map { OSStatus(CFErrorGetCode($0)) } ?? errSecNotTrusted
                let error = CertificateError(url: url, reason: .init(trustResult: result, status: code))
                self.ask(error, question: question, in: tab)
            }
        }
        // Not started: WebKit verifies it itself and fails the load if it does not verify.
        if status != errSecSuccess { resolve(question) { _ in (.performDefaultHandling, nil) } }
    }

    private func ask(_ error: CertificateError, question: TrustQuestion, in tab: WebKitTab?) {
        Task { @MainActor [weak tab] in
            var decision = CertificateErrorDecision.cancel
            if let tab, let delegate = tab.delegate {
                decision = await delegate.tab(tab, decideCertificateError: error)
            }
            guard let tab, let page = question.page, tab.webView === page else {
                // The tab closed or replaced its page meanwhile: its loads are over, and nothing is trusted.
                return self.resolve(question) { _ in (.cancelAuthenticationChallenge, nil) }
            }
            let proceed = decision == .proceed
            if answeredPage === page {
                navigationAnswers[question.key] = proceed
                if proceed { pageAllowances.insert(question.key) }
            }
            guard proceed else { return self.resolve(question) { _ in (.performDefaultHandling, nil) } }
            self.resolve(question) { trust in (.useCredential, URLCredential(trust: trust)) }
        }
    }

    /// Answers every challenge waiting on `question`, each with `disposition` of its own trust.
    private func resolve(
        _ question: TrustQuestion, _ disposition: (SecTrust) -> (URLSession.AuthChallengeDisposition, URLCredential?)
    ) {
        questions.removeAll { $0 === question }
        let waiters = question.waiters
        question.waiters = []
        for waiter in waiters {
            let (answer, credential) = disposition(waiter.trust)
            waiter.completionHandler(answer, credential)
        }
    }
}
