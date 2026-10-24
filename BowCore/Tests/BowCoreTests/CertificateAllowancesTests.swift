import BowCore
import Foundation
import Testing

@Suite struct CertificateAllowancesTests {
    let cert = Data([0x30, 0x82, 0x01])
    let otherCert = Data([0x30, 0x82, 0x02])

    func error(_ url: String?, _ reason: CertificateError.Reason = .untrustedAuthority) -> CertificateError {
        CertificateError(url: url.flatMap { URL(string: $0) }, reason: reason)
    }

    @Test func overridableErrorsAreOfferedForStandardHosts() {
        let overridable: [CertificateError.Reason] = [
            .nameMismatch, .dateInvalid, .untrustedAuthority, .noRevocationMechanism, .unableToCheckRevocation,
            .weakSignature, .nonUniqueName,
            .weakKey, .nameConstraintViolation, .validityTooLong, .notPubliclyLogged, .selfSignedLocalNetwork,
        ]
        #expect(CertificateAllowances.overridableReasons == Set(overridable))
        for reason in overridable {
            #expect(
                CertificateAllowances.mayOffer(error("https://example.com/", reason), enforcement: .standard),
                "\(reason)")
        }
    }

    @Test func fatalAndUnknownErrorsAreNeverOffered() {
        // Malformed, revoked, invalid, a distrusted authority, and a reason Bow does not know.
        let fatal: [CertificateError.Reason] = [.containsErrors, .revoked, .invalid, .distrustedAuthority, .other]
        for reason in fatal {
            #expect(
                !CertificateAllowances.mayOffer(error("https://example.com/", reason), enforcement: .standard),
                "\(reason)")
        }
        // Every reason is either overridable or fatal.
        #expect(
            Set(CertificateError.Reason.allCases) == CertificateAllowances.overridableReasons.union(fatal))
    }

    @Test func strictHostsAreNeverOffered() {
        #expect(!CertificateAllowances.mayOffer(error("https://example.com/"), enforcement: .strict))
    }

    @Test func unknownEnforcementCountsAsStrict() {
        #expect(!CertificateAllowances.mayOffer(error("https://example.com/"), enforcement: .unknown))
        var allowances = CertificateAllowances()
        let allowed = allowances.allow(error("https://example.com/"), certificate: cert, enforcement: .unknown)
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
        #expect(
            allowances.decision(for: error("https://example.com/"), certificate: cert, enforcement: .standard) == nil)
    }

    @Test func goingOnIsRememberedForTheHostAndCertificate() {
        var allowances = CertificateAllowances()
        let allowed = allowances.allow(error("https://example.com/a"), certificate: cert, enforcement: .standard)
        #expect(allowed)
        // Another page and port on the same host, and the host in other cases or with a trailing dot.
        let urls = [
            "https://example.com/b", "https://example.com:8443/", "https://EXAMPLE.com/", "https://example.com./",
        ]
        for url in urls {
            #expect(allowances.decision(for: error(url), certificate: cert, enforcement: .standard) == .proceed)
        }
    }

    @Test func anotherCertificateOnTheSameHostIsStillAsked() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/"), certificate: cert, enforcement: .standard)
        #expect(
            allowances.decision(for: error("https://example.com/"), certificate: otherCert, enforcement: .standard)
                == nil)
        #expect(
            allowances.decision(for: error("https://example.com/"), certificate: Data(), enforcement: .standard) == nil)
    }

    @Test func anUnknownCertificateIsNeverRemembered() {
        var allowances = CertificateAllowances()
        let allowed = allowances.allow(error("https://example.com/"), certificate: Data(), enforcement: .standard)
        #expect(!allowed)
        #expect(allowances.isEmpty)
    }

    @Test func otherHostsAreStillAsked() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/"), certificate: cert, enforcement: .standard)
        #expect(
            allowances.decision(for: error("https://www.example.com/"), certificate: cert, enforcement: .standard)
                == nil)
        #expect(
            allowances.decision(for: error("https://example.org/"), certificate: cert, enforcement: .standard) == nil)
    }

    @Test func anotherErrorOnTheSameHostIsStillAsked() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/", .untrustedAuthority), certificate: cert, enforcement: .standard)
        #expect(
            allowances.decision(
                for: error("https://example.com/", .dateInvalid), certificate: cert, enforcement: .standard)
                == nil)
        allowances.allow(error("https://example.com/", .dateInvalid), certificate: cert, enforcement: .standard)
        #expect(
            allowances.decision(
                for: error("https://example.com/", .dateInvalid), certificate: cert, enforcement: .standard)
                == .proceed)
        #expect(
            allowances.decision(
                for: error("https://example.com/", .untrustedAuthority), certificate: cert, enforcement: .standard)
                == .proceed)
    }

    @Test func aHostThatTurnedStrictIsAskedAgain() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/"), certificate: cert, enforcement: .standard)
        #expect(allowances.decision(for: error("https://example.com/"), certificate: cert, enforcement: .strict) == nil)
        #expect(
            allowances.decision(for: error("https://example.com/"), certificate: cert, enforcement: .unknown) == nil)
    }

    @Test func fatalErrorsAndStrictHostsAreNeverRemembered() {
        var allowances = CertificateAllowances()
        let revoked = allowances.allow(
            error("https://example.com/", .revoked), certificate: cert, enforcement: .standard)
        let strict = allowances.allow(error("https://example.com/"), certificate: cert, enforcement: .strict)
        let noHost = allowances.allow(error(nil), certificate: cert, enforcement: .standard)
        #expect(!revoked && !strict && !noHost)
        #expect(allowances.isEmpty)
        #expect(
            allowances.decision(for: error("https://example.com/", .revoked), certificate: cert, enforcement: .standard)
                == nil)
    }

    @Test func aNewSessionStartsWithNone() {
        var allowances = CertificateAllowances()
        allowances.allow(error("https://example.com/"), certificate: cert, enforcement: .standard)
        allowances.removeAll()
        #expect(allowances.isEmpty)
        #expect(
            allowances.decision(for: error("https://example.com/"), certificate: cert, enforcement: .standard) == nil)
        #expect(
            CertificateAllowances().decision(
                for: error("https://example.com/"), certificate: cert, enforcement: .standard) == nil)
    }
}
