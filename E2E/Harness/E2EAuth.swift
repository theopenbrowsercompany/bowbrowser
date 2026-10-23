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
    /// For each pane of `page`'s window, leading to trailing: the frame of the certificate error page over it in the
    /// page area, and the pane's own frame there, or nil for a pane no page covers.
    func certificateCovers(besides page: any E2EPage) throws -> [E2ECertificateCover?]
    /// Whether the keyboard of `page`'s window is in a certificate error page.
    func certificatePageHasKeyboard(besides page: any E2EPage) throws -> Bool
    /// Presses and releases Return in `page`'s window as the keyboard does: the key events go through the window's
    /// own dispatch to whatever has the keyboard.
    func pressReturn(in page: any E2EPage) throws
    /// What the URL fields of `page`'s window show: the sidebar's and the top tabs layout's.
    func addressFields(of page: any E2EPage) throws -> E2EAddressFields
    /// From now on, records every sign in question the page of the newest popup panel over `page`'s window asks, and
    /// the panel's answer, readable after the panel and its window have gone. The panel still answers them all.
    func recordPanelChallenges(besides page: any E2EPage) throws -> any E2EAuthRecording
    /// The sign in sheet up on the newest popup panel over `page`'s window, or nil when none is.
    func panelSignInSheet(besides page: any E2EPage) throws -> E2ESignInSheet?
    /// Types into the newest popup panel's sign in sheet and presses Sign In, or presses Cancel when `user` is nil.
    func answerPanelSignInSheet(besides page: any E2EPage, user: String?, password: String?) throws
}

/// The sign in questions a page asked and how each was answered, oldest first.
@MainActor
protocol E2EAuthRecording: AnyObject {
    var auth: [E2EAuthQuestion] { get }
}

/// A certificate error page over a pane, as a test reads it.
struct E2ECertificateCover: Equatable, CustomStringConvertible {
    /// The page's frame in the page area.
    var frame: CGRect
    /// Its pane's frame in the page area.
    var paneFrame: CGRect

    var description: String {
        "\(Int(frame.minX))+\(Int(frame.width))x\(Int(frame.height)) over \(Int(paneFrame.minX))+\(Int(paneFrame.width))"
    }
}

/// The URL fields of a window, as a test reads them.
struct E2EAddressFields: Equatable, CustomStringConvertible {
    var sidebarText: String
    var sidebarNotSecure: Bool
    var topTabsText: String
    var topTabsNotSecure: Bool

    var description: String {
        "sidebar=\"\(sidebarText)\"\(sidebarNotSecure ? " not-secure" : "") "
            + "top-tabs=\"\(topTabsText)\"\(topTabsNotSecure ? " not-secure" : "")"
    }
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
    /// The window and its sheet are still on no screen, as an e2e window must stay.
    var offScreen: Bool

    var description: String {
        "title=\"\(title)\" message=\"\(message)\" buttons=\(buttons.joined(separator: "+"))"
            + (offScreen ? "" : " on-screen")
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
