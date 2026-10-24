import BowCore
import Foundation
import Security
import Testing

@testable import BowWebKit

/// A server certificate that fails to verify reaches `EngineTabDelegate.tab(_:decideCertificateError:)` from real
/// web views, against a loopback HTTPS server with a self signed identity.
@Suite(.serialized) @MainActor struct ServerTrustTests {
    init() {
        TestHost.start()
    }

    private func secureServer() throws -> TLSListener {
        try TLSListener.started { path in
            path == "/image.svg"
                ? FixtureServer.Response(
                    status: 200, headers: ["Content-Type: image/svg+xml"],
                    body: Data("<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'/>".utf8))
                : .html("<!doctype html><title>Secure</title>")
        }
    }

    private func failReasons(_ rig: TabRig) -> [NavigationError.Reason] {
        rig.delegate.events.compactMap { if case .didFail(_, let error) = $0 { error.reason } else { nil } }
    }

    @Test func aSelfSignedCertificateLoadsOnlyWhenTheAppProceeds() async throws {
        let rig = try TabRig()
        let server = try secureServer()
        defer { server.stop() }
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        delegate.certificateDecision = { _ in .proceed }
        let tab = try await delegate.tab(in: rig)
        let url = server.url("/secure")
        tab.load(url)
        try await waitUntil("the page finished") {
            finishStatus(rig, url) == 200 && delegate.certificateErrors.count == 1 && tab.state.title == "Secure"
        }
        #expect(delegate.certificateErrors == [CertificateError(url: url, reason: .untrustedAuthority)])
        #expect(rig.delegate.navigation == ["start \(url)", "commit \(url)", "finish \(url)"])
        #expect(server.requests == ["/secure"])
        #expect(try await pageTitle(tab) == "Secure")

        // The page's own later loads from the same server and certificate go through without a new question.
        let text =
            try await tab.webView?.callAsyncJavaScript(
                "const r = await fetch('/later'); return r.ok ? await r.text() : 'failed ' + r.status",
                contentWorld: .page) as? String
        #expect(text?.contains("Secure") == true)
        #expect(server.requests == ["/secure", "/later"])
        #expect(delegate.certificateErrors.count == 1)
        try await rig.finish()
    }

    @Test func anotherLoadsCertificateIsRefusedWithoutAsking() async throws {
        let rig = try TabRig()
        let server = try secureServer()
        defer { server.stop() }
        let image = server.url("/image.svg")
        rig.server.route("/mixed") { _ in
            .html(
                "<!doctype html><title>Mixed</title><img id=i src=\"\(image)\" onerror=\"document.title='Refused'\" onload=\"document.title='Loaded'\">"
            )
        }
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        delegate.certificateDecision = { _ in .proceed }
        let tab = try await delegate.tab(in: rig)
        let url = rig.url("/mixed")
        tab.load(url)
        try await waitUntil("the page finished with its image refused") {
            finishStatus(rig, url) == 200 && tab.state.title == "Refused"
        }
        #expect(delegate.certificateErrors.isEmpty)
        #expect(server.requests.isEmpty)
        try await rig.finish()
    }

    @Test func aRefusedCertificateFailsTheLoadWithACertificateError() async throws {
        let rig = try TabRig()
        let server = try secureServer()
        defer { server.stop() }
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        let tab = try await delegate.tab(in: rig)
        let start = rig.url("/navigation/start.html")
        let url = server.url("/secure")
        tab.load(url)
        try await waitUntil("the load failed") {
            rig.delegate.navigation.contains("fail \(url)") && delegate.certificateErrors.count == 1
                && !tab.state.isLoading && tab.state.url == start
        }
        #expect(delegate.certificateErrors == [CertificateError(url: url, reason: .untrustedAuthority)])
        #expect(rig.delegate.navigation == ["start \(url)", "fail \(url)"])
        #expect(failReasons(rig) == [.certificate])
        #expect(server.requests.isEmpty)
        // The page shown before stays.
        #expect(tab.state.url == start)

        // The refusal lasted only for its navigation: loading the address again asks again.
        rig.delegate.reset()
        tab.load(url)
        try await waitUntil("the second load failed") {
            rig.delegate.navigation.contains("fail \(url)") && delegate.certificateErrors.count == 2
                && !tab.state.isLoading
        }
        #expect(failReasons(rig) == [.certificate])
        #expect(server.requests.isEmpty)
        try await rig.finish()
    }

    @Test func aTabClosedWhileAskedNeverTrustsTheCertificate() async throws {
        let rig = try TabRig()
        let server = try secureServer()
        defer { server.stop() }
        let delegate = ChallengeDelegate(recorder: rig.delegate)
        let later = LaterAnswer<CertificateErrorDecision>()
        delegate.certificateDecision = { _ in await later.wait() }
        let tab = try await delegate.tab(in: rig)
        tab.load(server.url("/secure"))
        try await waitUntil("the certificate question is open") {
            later.isWaiting && delegate.certificateErrors.count == 1
        }
        _ = await tab.close()
        rig.delegate.reset()
        later.give(.proceed)
        try await waitUntil("the late answer was given") { delegate.answered == 1 }
        #expect(server.requests.isEmpty)
        #expect(rig.delegate.events.isEmpty)
        try await rig.finish()
    }

    @Test func trustErrorsMapToBowReasons() {
        let failure = SecTrustResultType.recoverableTrustFailure
        #expect(CertificateError.Reason(trustResult: failure, status: errSecHostNameMismatch) == .nameMismatch)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecCertificateExpired) == .dateInvalid)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecCertificateNotValidYet) == .dateInvalid)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecNotTrusted) == .untrustedAuthority)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecCreateChainFailed) == .untrustedAuthority)
        #expect(CertificateError.Reason(trustResult: .deny, status: errSecTrustSettingDeny) == .distrustedAuthority)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecCertificateRevoked) == .revoked)
        #expect(
            CertificateError.Reason(trustResult: failure, status: errSecIncompleteCertRevocationCheck)
                == .unableToCheckRevocation)
        #expect(
            CertificateError.Reason(trustResult: failure, status: errSecCertificateNameNotAllowed)
                == .nameConstraintViolation)
        #expect(
            CertificateError.Reason(trustResult: failure, status: errSecCertificateValidityPeriodTooLong)
                == .validityTooLong)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecInvalidDigestAlgorithm) == .weakSignature)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecUnsupportedKeySize) == .weakKey)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecDecode) == .containsErrors)
        #expect(CertificateError.Reason(trustResult: failure, status: errSecInvalidExtendedKeyUsage) == .invalid)
        // A code Bow does not know: the result tells a distrust or a fatal error from the rest.
        #expect(CertificateError.Reason(trustResult: .deny, status: -1) == .distrustedAuthority)
        #expect(CertificateError.Reason(trustResult: .fatalTrustFailure, status: -1) == .invalid)
        #expect(CertificateError.Reason(trustResult: failure, status: -1) == .other)
    }
}
