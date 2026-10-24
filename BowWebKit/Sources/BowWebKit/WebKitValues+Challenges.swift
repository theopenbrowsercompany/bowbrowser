import BowCore
import Foundation
import Security

// Authentication challenges in Bow's terms. Nothing here switches over a BowCore enum.

extension AuthChallenge {
    /// Bow's scheme name for the HTTP sign in methods Bow answers (`basic`, `digest`, as Chromium names them), nil
    /// for every other method, which WebKit handles itself.
    static func scheme(authenticationMethod method: String) -> String? {
        switch method {
        // The default method is HTTP basic (Foundation's documentation).
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodDefault: "basic"
        case NSURLAuthenticationMethodHTTPDigest: "digest"
        default: nil
        }
    }

    /// The question for a sign in challenge with the scheme `scheme`: the address that asked is the response that
    /// asked, else the main frame's navigation when it goes to the same server, else the server's root.
    init(_ challenge: URLAuthenticationChallenge, scheme: String, navigationURL: URL?) {
        let space = challenge.protectionSpace
        self.init(
            url: challenge.failureResponse?.url ?? Self.address(of: space, navigationURL: navigationURL),
            host: space.host, port: space.port, realm: space.realm ?? "", scheme: scheme, isProxy: space.isProxy())
    }

    /// `navigationURL` when it goes to the protection space's server, else the server's root address.
    static func address(of space: URLProtectionSpace, navigationURL: URL?) -> URL? {
        let scheme = space.isProxy() ? "http" : (space.protocol ?? "https")
        if let navigationURL, navigationURL.host == space.host, navigationURL.scheme == scheme,
            (navigationURL.port ?? defaultPort(scheme)) == space.port
        {
            return navigationURL
        }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = space.host
        if space.port != defaultPort(scheme) { parts.port = space.port }
        parts.path = "/"
        return parts.url
    }

    private static func defaultPort(_ scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }
}

extension CertificateError.Reason {
    /// The reason a server trust failed to verify, from the trust result and the error code
    /// `SecTrustEvaluateWithError` gave (Security's `SecBase.h`). The code says what failed; the result only
    /// tells an explicit distrust or a fatal error from the rest when the code is not one Bow knows.
    init(trustResult result: SecTrustResultType, status: OSStatus) {
        switch status {
        case errSecHostNameMismatch: self = .nameMismatch
        case errSecCertificateExpired, errSecCertificateNotValidYet: self = .dateInvalid
        case errSecNotTrusted, errSecCreateChainFailed: self = .untrustedAuthority
        // The Mac's trust settings say never to trust it.
        case errSecTrustSettingDeny: self = .distrustedAuthority
        case errSecCertificateRevoked: self = .revoked
        case errSecIncompleteCertRevocationCheck, errSecOCSPNotTrustedToAnchor: self = .unableToCheckRevocation
        case errSecCertificateNameNotAllowed: self = .nameConstraintViolation
        case errSecCertificateValidityPeriodTooLong: self = .validityTooLong
        case errSecInvalidDigestAlgorithm: self = .weakSignature
        case errSecUnsupportedKeySize: self = .weakKey
        case errSecUnknownFormat, errSecDecode, errSecInvalidCertificateRef, errSecInvalidData: self = .containsErrors
        case errSecInvalidExtendedKeyUsage, errSecInvalidKeyUsageForPolicy, errSecMissingRequiredExtension,
            errSecCertificateCannotOperate, errSecCertificatePolicyNotAllowed:
            self = .invalid
        default:
            switch result {
            case .deny: self = .distrustedAuthority
            case .fatalTrustFailure: self = .invalid
            default: self = .other
            }
        }
    }
}
