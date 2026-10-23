import Foundation

// When a certificate error page may offer to go on to the site anyway, and the hosts a person chose to go on to.
// The rules follow Chrome's: only errors Chrome lets a person override, never for a host that requires valid HTTPS
// (HSTS or pinned keys, which Chrome calls strict enforcement), and an allowance lasts for the session only.

/// Whether the engine enforces a host's certificate strictly: a host that sent HSTS or is on the preloaded HSTS
/// list, or whose keys are pinned. Chrome offers no way past a strict host's certificate errors.
public enum CertificateEnforcement: Equatable, Sendable {
    /// The engine said the host has no strict rules.
    case standard
    /// The host requires valid HTTPS.
    case strict
    /// The engine did not say, which counts as strict. CEF 156 never says: `OnCertificateError` takes no
    /// strict enforcement flag, and CEF drops the one Chromium hands it.
    case unknown
}

/// The certificate errors a person chose to go past this session, per host. Kept in memory only and never saved: it
/// is deliberately not `Codable`, and a new session starts with none.
public struct CertificateAllowances: Equatable, Sendable {
    /// The engine's certificate error codes Chrome lets a person go past when the host is not strict: an untrusted
    /// authority, a name or date mismatch, and the other errors that do not prove the certificate is bad. Revoked,
    /// invalid and pinned key errors, codes not listed (unknown or newer ones), and known interception (which Chrome
    /// shows its own blocking page for) are never offered.
    public static let overridableCodes: Set<Int> = [
        -200,  // ERR_CERT_COMMON_NAME_INVALID
        -201,  // ERR_CERT_DATE_INVALID
        -202,  // ERR_CERT_AUTHORITY_INVALID
        -204,  // ERR_CERT_NO_REVOCATION_MECHANISM
        -205,  // ERR_CERT_UNABLE_TO_CHECK_REVOCATION
        -208,  // ERR_CERT_WEAK_SIGNATURE_ALGORITHM
        -210,  // ERR_CERT_NON_UNIQUE_NAME
        -211,  // ERR_CERT_WEAK_KEY
        -212,  // ERR_CERT_NAME_CONSTRAINT_VIOLATION
        -213,  // ERR_CERT_VALIDITY_TOO_LONG
        -214,  // ERR_CERTIFICATE_TRANSPARENCY_REQUIRED
        -219,  // ERR_CERT_SELF_SIGNED_LOCAL_NETWORK
    ]

    /// Error codes allowed so far, by host.
    private var allowed: [String: Set<Int>] = [:]

    public init() {}

    /// True when the error page may offer to go on past `error`: its code is overridable, the engine said the host
    /// is not strict, and the error names a host.
    public static func mayOffer(_ error: CertificateError, enforcement: CertificateEnforcement) -> Bool {
        enforcement == .standard && overridableCodes.contains(error.code) && host(of: error) != nil
    }

    /// Remembers, for this session, that the person chose to go on past `error` on its host. Remembers nothing and
    /// returns false when going on may not be offered (`mayOffer`).
    @discardableResult
    public mutating func allow(_ error: CertificateError, enforcement: CertificateEnforcement) -> Bool {
        guard Self.mayOffer(error, enforcement: enforcement), let host = Self.host(of: error) else { return false }
        allowed[host, default: []].insert(error.code)
        return true
    }

    /// What to do with `error` without asking: `.proceed` when the person already went past the same error on the
    /// same host this session and going on may still be offered (a host that turned strict since is asked again),
    /// nil to show the error page.
    public func decision(for error: CertificateError, enforcement: CertificateEnforcement) -> CertificateErrorDecision? {
        guard Self.mayOffer(error, enforcement: enforcement), let host = Self.host(of: error),
            allowed[host]?.contains(error.code) == true
        else { return nil }
        return .proceed
    }

    /// Forgets every allowance, as at the end of a session.
    public mutating func removeAll() {
        allowed.removeAll()
    }

    /// True when nothing is allowed.
    public var isEmpty: Bool { allowed.isEmpty }

    /// The error's host, lowercased and without a trailing dot, or nil when it has none. The port is left out, as
    /// Chrome remembers its decisions per host.
    static func host(of error: CertificateError) -> String? {
        guard var host = error.url?.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}
