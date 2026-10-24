import Foundation

// Questions a load asks the app before it can go on: HTTP sign in and certificate errors.

/// A server (or proxy) asked for a user name and password.
public struct AuthChallenge: Equatable, Sendable {
    /// The URL that asked.
    public var url: URL?
    public var host: String
    public var port: Int
    /// The realm the server named, empty when none.
    public var realm: String
    /// The scheme, for example `basic` or `digest`.
    public var scheme: String
    public var isProxy: Bool

    public init(url: URL?, host: String, port: Int, realm: String, scheme: String, isProxy: Bool = false) {
        self.url = url
        self.host = host
        self.port = port
        self.realm = realm
        self.scheme = scheme
        self.isProxy = isProxy
    }
}

/// The answer to an auth challenge.
public struct AuthCredentials: Equatable, Sendable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }
}

/// A page's certificate failed to verify.
public struct CertificateError: Equatable, Sendable {
    /// What is wrong with a certificate. Each engine maps its own verification results to these.
    public enum Reason: Hashable, Sendable, CaseIterable {
        /// It names a different site than the one loaded.
        case nameMismatch
        /// It has expired or is not valid yet.
        case dateInvalid
        /// It is not from an authority the Mac trusts (self-signed, or an unknown authority).
        case untrustedAuthority
        /// It is malformed.
        case containsErrors
        /// It names no way to check whether it was revoked.
        case noRevocationMechanism
        /// Whether it was revoked could not be checked.
        case unableToCheckRevocation
        /// Its authority revoked it.
        case revoked
        /// It is not valid for another reason.
        case invalid
        /// It is signed with a weak algorithm.
        case weakSignature
        /// It names a site whose name is not unique (an internal name or a private address).
        case nonUniqueName
        /// Its key is too weak.
        case weakKey
        /// It names a site its authority may not certify.
        case nameConstraintViolation
        /// It is valid for longer than allowed.
        case validityTooLong
        /// It was not publicly logged, as Certificate Transparency requires.
        case notPubliclyLogged
        /// Its authority is no longer trusted.
        case distrustedAuthority
        /// It is self-signed by a device on the local network.
        case selfSignedLocalNetwork
        /// The engine gave no reason Bow knows.
        case other
    }

    public var url: URL?
    public var reason: Reason

    public init(url: URL?, reason: Reason) {
        self.url = url
        self.reason = reason
    }
}

/// What to do with a certificate error.
public enum CertificateErrorDecision: Equatable, Sendable {
    /// Load the page anyway.
    case proceed
    /// Stop the load; the engine shows its error page and the navigation fails. The default.
    case cancel
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials? {
        nil
    }

    public func tab(_ tab: any EngineTab, decideCertificateError error: CertificateError) async
        -> CertificateErrorDecision
    {
        .cancel
    }
}
