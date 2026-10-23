import Foundation

/// A window's sign in sheet and certificate error page as a test sees them, answered the way a person answers them:
/// typing into the sheet's fields and pressing its buttons, pressing the page's Go back.
/// E2E/Harness/E2EAppAdapter+Auth.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EAuthApp: E2EApp {
    /// The sign in sheet up on `page`'s window, or nil when none is.
    func signInSheet(besides page: any E2EPage) throws -> E2ESignInSheet?
    /// Whether `page`'s tab has a sign in request up or waiting for its tab to be shown.
    func signInWaits(for page: any E2EPage) throws -> Bool
    /// Whether `page`'s window holds no sign in request, no sign in sheet and no sheet of any kind.
    func signInIdle(besides page: any E2EPage) throws -> Bool
    /// Types `user` and `password` into the sheet up on `page`'s window and presses Sign In, or presses Cancel when
    /// `user` is nil. Throws when no sheet is up.
    func answerSignInSheet(besides page: any E2EPage, user: String?, password: String?) throws
    /// The certificate error page `page`'s window shows over its page area, or nil when it shows none.
    func certificateErrorPage(besides page: any E2EPage) throws -> E2ECertificateErrorPage?
    /// Presses Go back on the certificate error page `page`'s window shows. Throws when it shows none.
    func pressCertificateGoBack(besides page: any E2EPage) throws
}

/// The sign in sheet as a test reads it.
struct E2ESignInSheet: Equatable, CustomStringConvertible {
    var title: String
    var message: String
    /// Its buttons' titles, in order.
    var buttons: [String]
    /// The title of the sheet's default button, the one Return presses; empty when it has none.
    var defaultButton: String
    /// The user name field holds no text and the password field is a secure field.
    var fieldsReady: Bool
    /// The sheet is attached to the window (not queued or floating).
    var isAttached: Bool

    var description: String {
        "title=\"\(title)\" message=\"\(message)\" buttons=\(buttons.joined(separator: "+"))"
            + " default=\(defaultButton.isEmpty ? "none" : defaultButton)" + (fieldsReady ? "" : " fields-not-ready")
            + (isAttached ? "" : " detached")
    }
}

/// The certificate error page as a test reads it.
struct E2ECertificateErrorPage: Equatable, CustomStringConvertible {
    var title: String
    var message: String
    var detail: String
    /// The titles of every button on the page, in order.
    var buttons: [String]

    var description: String {
        "title=\"\(title)\" message=\"\(message)\" detail=\(detail) buttons=\(buttons.joined(separator: "+"))"
    }
}
