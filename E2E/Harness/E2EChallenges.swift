import Foundation

/// The questions a load asks the window before it can go on (HTTP sign in, certificate errors), as a test sees them.
/// E2E/Harness/E2EAppAdapter+Challenges.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EChallengesApp: E2EApp {
    /// From now on, records every sign in and certificate question `page`'s tab asks its window, and the answer the
    /// window gave. The window still answers them all.
    func recordChallenges(of page: any E2EPage) throws
    /// The sign in questions recorded so far for `page`, oldest first.
    func authChallenges(of page: any E2EPage) throws -> [E2EAuthQuestion]
    /// The certificate questions recorded so far for `page`, oldest first.
    func certificateErrors(of page: any E2EPage) throws -> [E2ECertificateQuestion]
}

/// One sign in question and the window's answer.
struct E2EAuthQuestion: CustomStringConvertible {
    var host: String
    var port: Int
    var realm: String
    var scheme: String
    var isProxy: Bool
    /// The user name the window answered with, or nil when it cancelled. Nil too while it has not answered yet.
    var answeredUser: String?
    var answered: Bool

    var description: String {
        let answer = answered ? (answeredUser.map { "user \($0)" } ?? "cancel") : "pending"
        return "\(scheme) \(host):\(port) realm=\(realm)\(isProxy ? " proxy" : "") answer=\(answer)"
    }
}

/// One certificate question and the window's answer.
struct E2ECertificateQuestion: CustomStringConvertible {
    var url: URL?
    /// The name of what is wrong with the certificate (BowCore's `CertificateError.Reason`, for example
    /// `untrustedAuthority`).
    var reason: String
    /// True when the window let the load go on; nil while it has not answered.
    var proceeded: Bool?

    var description: String {
        let answer = proceeded.map { $0 ? "proceed" : "cancel" } ?? "pending"
        return "\(url?.absoluteString ?? "no URL") \(reason) answer=\(answer)"
    }
}
