import BowCore
import CryptoKit
import Foundation
import Testing

@testable import BowWebKit

/// A tab delegate for the challenge tests: it hands navigation events and policy to the rig's recording delegate,
/// records every sign in and certificate question, and answers each with the test's closure, which may wait as
/// long as the test needs (a person deciding).
@MainActor
final class ChallengeDelegate: EngineTabDelegate {
    let recorder: RecordingTabDelegate
    private(set) var signIns: [AuthChallenge] = []
    private(set) var certificateErrors: [CertificateError] = []
    /// Questions the closures have answered so far.
    private(set) var answered = 0
    var credentials: @MainActor (AuthChallenge) async -> AuthCredentials? = { _ in nil }
    var certificateDecision: @MainActor (CertificateError) async -> CertificateErrorDecision = { _ in .cancel }

    init(recorder: RecordingTabDelegate) {
        self.recorder = recorder
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        recorder.tab(tab, didReceive: event)
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        recorder.tab(tab, decidePolicyFor: navigation)
    }

    func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials? {
        signIns.append(challenge)
        let answer = await credentials(challenge)
        answered += 1
        return answer
    }

    func tab(_ tab: any EngineTab, decideCertificateError error: CertificateError) async -> CertificateErrorDecision {
        certificateErrors.append(error)
        let decision = await certificateDecision(error)
        answered += 1
        return decision
    }

    /// A tab of `rig` that has loaded its first page, with this delegate in place of the rig's, and the rig's
    /// events so far forgotten.
    func tab(in rig: TabRig) async throws -> WebKitTab {
        let start = rig.url("/navigation/start.html")
        let tab = rig.tab("/navigation/start.html")
        tab.delegate = self
        try await rig.waitFor("finish \(start)")
        rig.delegate.reset()
        return tab
    }
}

/// An answer the test gives later: the delegate's closure waits on it.
@MainActor
final class LaterAnswer<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    var isWaiting: Bool { continuation != nil }

    func wait() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }

    func give(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// The page's title, read from the page itself.
@MainActor
func pageTitle(_ tab: WebKitTab) async throws -> String? {
    try await tab.webView?.callAsyncJavaScript("return document.title", contentWorld: .page) as? String
}

/// The status of the finish of the navigation to `url`, nil before it finished.
@MainActor
func finishStatus(_ rig: TabRig, _ url: URL) -> Int? {
    rig.delegate.events.lazy.compactMap { event -> Int? in
        if case .didFinish(let navigation, let status) = event, navigation.url == url { status } else { nil }
    }.first
}

/// HTTP basic and digest sign in reach `EngineTabDelegate.tab(_:answer:)` from real web views.
@Suite(.serialized) @MainActor struct AuthChallengeTests {
    init() {
        TestHost.start()
    }

    nonisolated private static let user = "ada"
    nonisolated private static let password = "lovelace"
    nonisolated private static let denied = "<!doctype html><title>Denied</title><p>The server's own page"

    /// `/basic`: the page for the right basic credentials, else a 401 asking for them.
    private func routeBasic(_ rig: TabRig) {
        let expected = "Basic " + Data("\(Self.user):\(Self.password)".utf8).base64EncodedString()
        rig.server.route("/basic") { request in
            request.headers["authorization"] == expected
                ? .html("<!doctype html><title>Signed in</title>")
                : .html(Self.denied, status: 401, headers: ["WWW-Authenticate: Basic realm=\"Bow test\""])
        }
    }

    @Test func basicSignInAnsweredLoadsTheProtectedPage() async throws {
        let rig = try TabRig()
        routeBasic(rig)
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        delegate.credentials = { _ in AuthCredentials(user: Self.user, password: Self.password) }
        let tab = try await delegate.tab(in: rig)
        let url = rig.url("/basic")
        tab.load(url)
        try await waitUntil("the signed in page finished") {
            finishStatus(rig, url) == 200 && delegate.signIns.count == 1 && tab.state.title == "Signed in"
        }
        #expect(
            delegate.signIns == [
                AuthChallenge(
                    url: url, host: "127.0.0.1", port: Int(rig.server.port), realm: "Bow test", scheme: "basic")
            ])
        #expect(rig.delegate.navigation == ["start \(url)", "commit \(url)", "finish \(url)"])
        #expect(try await pageTitle(tab) == "Signed in")

        // The answer is kept for the session: the same realm is not asked about again.
        rig.delegate.reset()
        tab.reload()
        try await waitUntil("the reload finished") {
            finishStatus(rig, url) == 200 && tab.state.title == "Signed in"
        }
        #expect(delegate.signIns.count == 1)

        // Another profile keeps nothing of it: its tab is asked again.
        let other = WebKitProfile(profileID: "Other", storeID: UUID(), isPersistent: false, store: .nonPersistent())
        let otherDelegate = ChallengeDelegate(recorder: RecordingTabDelegate())
        let otherTab = other.createTab(url: url) as! WebKitTab
        otherTab.delegate = otherDelegate
        if let webView = otherTab.webView { WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false) }
        try await waitUntil("the other profile's tab finished on the 401 page") {
            otherDelegate.signIns.count == 1 && otherTab.state.title == "Denied" && !otherTab.state.isLoading
        }
        let box = otherTab.webView.map(WeakBox.init)
        _ = await otherTab.close()
        try await waitUntil("the other profile's web view is released", timeout: 5) { box?.object == nil }
        try await rig.finish()
    }

    @Test func digestSignInAnsweredLoadsTheProtectedPage() async throws {
        let rig = try TabRig()
        let realm = "Bow digest"
        let nonce = UUID().uuidString
        rig.server.route("/digest") { request in
            Self.digestIsValid(request, realm: realm, nonce: nonce)
                ? .html("<!doctype html><title>Signed in</title>")
                : .html(
                    Self.denied, status: 401,
                    headers: [
                        "WWW-Authenticate: Digest realm=\"\(realm)\", qop=\"auth\", nonce=\"\(nonce)\", algorithm=MD5"
                    ]
                )
        }
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        delegate.credentials = { _ in AuthCredentials(user: Self.user, password: Self.password) }
        let tab = try await delegate.tab(in: rig)
        let url = rig.url("/digest")
        tab.load(url)
        try await waitUntil("the signed in page finished") {
            finishStatus(rig, url) == 200 && delegate.signIns.count == 1 && tab.state.title == "Signed in"
        }
        #expect(
            delegate.signIns == [
                AuthChallenge(url: url, host: "127.0.0.1", port: Int(rig.server.port), realm: realm, scheme: "digest")
            ])
        // Digest never sends the password itself.
        #expect(!rig.server.log().contains { ($0.headers["authorization"] ?? "").contains(Self.password) })
        try await rig.finish()
    }

    @Test func noAnswerShowsTheServersOwn401Page() async throws {
        let rig = try TabRig()
        routeBasic(rig)
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        let tab = try await delegate.tab(in: rig)
        let url = rig.url("/basic")
        tab.load(url)
        try await waitUntil("the 401 page finished") {
            finishStatus(rig, url) == 401 && delegate.signIns.count == 1 && tab.state.title == "Denied"
        }
        #expect(rig.delegate.navigation == ["start \(url)", "commit \(url)", "finish \(url)"])
        #expect(try await pageTitle(tab) == "Denied")
        #expect(!rig.server.log().contains { $0.headers["authorization"] != nil })
        try await rig.finish()
    }

    @Test func aTabClosedWhileAskedSendsNoCredentials() async throws {
        let rig = try TabRig()
        routeBasic(rig)
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        let later = LaterAnswer<AuthCredentials?>()
        delegate.credentials = { _ in await later.wait() }
        let tab = try await delegate.tab(in: rig)
        tab.load(rig.url("/basic"))
        try await waitUntil("the sign in question is open") { later.isWaiting && delegate.signIns.count == 1 }
        _ = await tab.close()
        rig.delegate.reset()
        later.give(AuthCredentials(user: Self.user, password: Self.password))
        try await waitUntil("the late answer was given") { delegate.answered == 1 }
        #expect(!rig.server.log().contains { $0.headers["authorization"] != nil })
        #expect(rig.delegate.events.isEmpty)
        try await rig.finish()
    }

    @Test func signInSchemesAndAddresses() {
        #expect(AuthChallenge.scheme(authenticationMethod: NSURLAuthenticationMethodHTTPBasic) == "basic")
        #expect(AuthChallenge.scheme(authenticationMethod: NSURLAuthenticationMethodDefault) == "basic")
        #expect(AuthChallenge.scheme(authenticationMethod: NSURLAuthenticationMethodHTTPDigest) == "digest")
        #expect(AuthChallenge.scheme(authenticationMethod: NSURLAuthenticationMethodNTLM) == nil)
        #expect(AuthChallenge.scheme(authenticationMethod: NSURLAuthenticationMethodClientCertificate) == nil)
        #expect(AuthChallenge.scheme(authenticationMethod: NSURLAuthenticationMethodServerTrust) == nil)

        let space = URLProtectionSpace(
            host: "example.com", port: 8443, protocol: "https", realm: "r",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let page = URL(string: "https://example.com:8443/a?b")!
        #expect(AuthChallenge.address(of: space, navigationURL: page) == page)
        #expect(
            AuthChallenge.address(of: space, navigationURL: URL(string: "https://other.com:8443/a"))
                == URL(string: "https://example.com:8443/"))
        let plain = URLProtectionSpace(
            host: "example.com", port: 80, protocol: "http", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(
            AuthChallenge.address(of: plain, navigationURL: URL(string: "http://example.com/x"))
                == URL(string: "http://example.com/x"))
        #expect(AuthChallenge.address(of: plain, navigationURL: nil) == URL(string: "http://example.com/"))
    }

    // MARK: Digest (RFC 7616, MD5 with qop auth)

    nonisolated private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `key="value"` and `key=value` parameters of a Digest authorization header.
    nonisolated private static func digestParameters(_ header: String) -> [String: String] {
        guard header.hasPrefix("Digest ") else { return [:] }
        var result: [String: String] = [:]
        let pattern = /([a-z]+)=(?:"([^"]*)"|([^,\s]*))/
        for match in header.dropFirst("Digest ".count).matches(of: pattern) {
            result[String(match.1)] = String(match.2 ?? match.3 ?? "")
        }
        return result
    }

    nonisolated private static func digestIsValid(_ request: FixtureServer.Request, realm: String, nonce: String)
        -> Bool
    {
        let p = digestParameters(request.headers["authorization"] ?? "")
        guard p["username"] == user, p["realm"] == realm, p["nonce"] == nonce, p["qop"] == "auth",
            let uri = p["uri"], let nc = p["nc"], let cnonce = p["cnonce"], let response = p["response"]
        else { return false }
        let ha1 = md5("\(user):\(realm):\(password)")
        let ha2 = md5("\(request.method):\(uri)")
        return response == md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
    }
}
