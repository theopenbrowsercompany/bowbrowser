import BowCore
import Foundation
import Testing

@Suite struct CertificateAllowancesTests {
    func error(_ url: String?, _ code: Int = -202) -> CertificateError {
        CertificateError(url: url.flatMap { URL(string: $0) }, code: code)
    }

    @Test func overridableErrorsAreOfferedForStandardHosts() {
        for code in [-200, -201, -202, -213, -219] {
            #expect(CertificateAllowances.mayOffer(error("https://example.com/", code), enforcement: .standard))
        }
    }

    @Test func fatalErrorsAreNeverOffered() {
        // Contains errors, revoked, invalid, pinned key, known interception.
        for code in [-203, -206, -207, -150, -217] {
            #expect(!CertificateAllowances.mayOffer(error("https://example.com/", code), enforcement: .standard))
        }
    }

    @Test func unknownAndNonCertificateCodesAreNeverOffered() {
        for code in [-220, -209, -216, -218, -105, 0, 200] {
            #expect(!CertificateAllowances.mayOffer(error("https://example.com/", code), enforcement: .standard))
        }
    }

    @Test func strictHostsAreNeverOffered() {
        #expect(!CertificateAllowances.mayOffer(error("https://example.com/"), enforcement: .strict))
    }

    @Test func unknownEnforcementCountsAsStrict() {
        #expect(!CertificateAllowances.mayOffer(error("https://example.com/"), enforcement: .unknown))
        var allowances = CertificateAllowances()
        let allowed = allowances.allow(error("https://example.com/"), enforcement: .unknown)
        #expect(!allowed)
        #expect(allowances.isEmpty)
    }

    @Test func errorsWithoutAHostAreNeverOffered() {
        #expect(!CertificateAllowances.mayOffer(error(nil), enforcement: .standard))
        #expect(!CertificateAllowances.mayOffer(error("about:blank"), enforcement: .standard))
    }

    @Test func nothingIsAllowedAtFirst() {
        let allowances = CertificateAllowances()
        #expect(allowances.isEmpty)
        #expect(allowances.decision(for: error("https://example.com/"), enforcement: .standard) == nil)
    }

    @Test func goingOnIsRememberedForTheHost() {
        var allowances = CertificateAllowances()
        let allowed = allowances.allow(error("https://example.com/a"), enforcement: .standard)
        #expect(allowed)
        // Another page and port on the same host, and the host in other cases or with a trailing dot.
        for url in [
            "https://example.com/b", "https://example.com:8443/", "https://EXAMPLE.com/", "https://example.com./",
        ] {
            #expect(allowances.decision(for: error(url), enforcement: .standard) == .proceed)
        }
    }

    @Test func otherHostsAreStillAsked() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/"), enforcement: .standard)
        #expect(allowances.decision(for: error("https://www.example.com/"), enforcement: .standard) == nil)
        #expect(allowances.decision(for: error("https://example.org/"), enforcement: .standard) == nil)
    }

    @Test func anotherErrorOnTheSameHostIsStillAsked() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/", -202), enforcement: .standard)
        #expect(allowances.decision(for: error("https://example.com/", -201), enforcement: .standard) == nil)
        allowances.allow(error("https://example.com/", -201), enforcement: .standard)
        #expect(allowances.decision(for: error("https://example.com/", -201), enforcement: .standard) == .proceed)
        #expect(allowances.decision(for: error("https://example.com/", -202), enforcement: .standard) == .proceed)
    }

    @Test func aHostThatTurnedStrictIsAskedAgain() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/"), enforcement: .standard)
        #expect(allowances.decision(for: error("https://example.com/"), enforcement: .strict) == nil)
        #expect(allowances.decision(for: error("https://example.com/"), enforcement: .unknown) == nil)
    }

    @Test func fatalErrorsAndStrictHostsAreNeverRemembered() {
        var allowances = CertificateAllowances()
        let revoked = allowances.allow(error("https://example.com/", -206), enforcement: .standard)
        let strict = allowances.allow(error("https://example.com/"), enforcement: .strict)
        let noHost = allowances.allow(error(nil), enforcement: .standard)
        #expect(!revoked && !strict && !noHost)
        #expect(allowances.isEmpty)
        #expect(allowances.decision(for: error("https://example.com/", -206), enforcement: .standard) == nil)
    }

    @Test func aNewSessionStartsWithNone() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/"), enforcement: .standard)
        allowances.removeAll()
        #expect(allowances.isEmpty)
        #expect(allowances.decision(for: error("https://example.com/"), enforcement: .standard) == nil)
        #expect(CertificateAllowances().decision(for: error("https://example.com/"), enforcement: .standard) == nil)
    }
}
