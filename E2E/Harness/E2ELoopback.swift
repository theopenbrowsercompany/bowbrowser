import Foundation
// Links Network.framework, which BowLoopbackFixtures.mm listens with, into the Debug builds that carry the harness
// (Swift links the frameworks it imports), so Release links nothing for it.
import Network

/// The loopback fixtures (E2E/Engine/BowLoopbackFixtures): real sockets on 127.0.0.1, started for the run before
/// the engine and stopped after it, for what the in-process `https://bow.test/` server cannot give. Chromium's host
/// resolver rules send `auth.bow.test` and `badcert.bow.test` to them; every other host still resolves to nothing.
///
/// - `authURL` answers 401 with `WWW-Authenticate: Basic realm="bow"` until a request signs in as `authUser` with
///   `authPassword` (plain HTTP: over TLS the certificate below would fail first).
/// - `badCertificateURL` is served over TLS with a self-signed certificate, so loading it is a certificate error.
@MainActor
enum E2ELoopback {
    static let authHost = "auth.bow.test"
    static let certificateHost = "badcert.bow.test"
    static let authURL = URL(string: "http://\(authHost)/")!
    static let badCertificateURL = URL(string: "https://\(certificateHost)/")!
    static var authUser: String { BowLoopbackFixtures.authUser }
    static var authPassword: String { BowLoopbackFixtures.authPassword }

    private static var fixtures: BowLoopbackFixtures?
    /// Why the fixtures could not start, which every test that needs them fails with.
    private static var startFailure: String?

    /// Starts the fixtures and returns the host resolver rules that reach them, to put before the rule that
    /// blocks every other host. With the fixtures down it returns no rules, so those hosts stay blocked too.
    static func start() -> String {
        do {
            let started = try BowLoopbackFixtures.start()
            fixtures = started
            var rules = "MAP \(authHost) 127.0.0.1:\(started.authPort), "
            if started.certificateFailure == nil {
                rules += "MAP \(certificateHost) 127.0.0.1:\(started.certificatePort), "
            }
            return rules
        } catch {
            startFailure = error.localizedDescription
            return ""
        }
    }

    /// Stops the fixtures; nothing listens afterwards.
    static func stop() {
        fixtures?.stop()
        fixtures = nil
    }

    /// The running fixtures, or an error saying why they are not running.
    static func running() throws -> BowLoopbackFixtures {
        guard let fixtures else {
            throw E2EError("the loopback fixtures are not running: \(startFailure ?? "they were stopped")")
        }
        return fixtures
    }

    /// The running fixtures when their certificate listener runs too, or an error saying why it does not.
    static func runningWithCertificate() throws -> BowLoopbackFixtures {
        let fixtures = try running()
        if let failure = fixtures.certificateFailure {
            throw E2EError("the loopback certificate fixture is not running: \(failure)")
        }
        return fixtures
    }
}
