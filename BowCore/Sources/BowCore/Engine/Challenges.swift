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
    public var url: URL?
    /// The engine's network error code (for example -202 for an untrusted authority).
    public var code: Int

    public init(url: URL?, code: Int) {
        self.url = url
        self.code = code
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
