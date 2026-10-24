import Foundation

// The certificate error page: what it says, which tabs show it, and where Go back goes.

/// The page a tab shows instead of a page whose certificate failed to verify, in plain words: a short title,
/// the host, what is wrong with its certificate, and the error's name as Chrome (and so Arc) prints it. Its only
/// action is Go back; it offers no way on to the site (a way past waits until the engine can say whether the site
/// requires HTTPS, see `CertificateEnforcement`).
public struct CertificateErrorPage: Equatable, Sendable {
    public static let title = "This connection is not secure"
    public static let goBackTitle = "Go back"

    public var error: CertificateError

    public init(error: CertificateError) {
        self.error = error
    }

    /// The host the page names: the error's host, or "this site" when it has none.
    public var host: String {
        guard let host = error.url?.host, !host.isEmpty else { return "this site" }
        return host
    }

    /// The page's explanation: who could not be confirmed, why, and what could happen.
    public var message: String {
        "Bow could not confirm that this is the real \(host). \(reason) "
            + "Someone might be trying to steal what you send to it, such as passwords, messages or card numbers."
    }

    /// What is wrong with the certificate, in one plain sentence.
    public var reason: String {
        switch error.reason {
        case .nameMismatch: "Its certificate belongs to a different site."
        case .dateInvalid: "Its certificate has expired or is not valid yet."
        case .untrustedAuthority: "Its certificate is not from an authority this Mac trusts."
        case .containsErrors: "Its certificate contains errors."
        case .noRevocationMechanism, .unableToCheckRevocation: "Its certificate could not be checked for revocation."
        case .revoked: "Its certificate has been revoked by the authority that issued it."
        case .invalid: "Its certificate is not valid."
        case .weakSignature: "Its certificate uses a weak signature."
        case .nonUniqueName: "Its certificate names a site that is not unique."
        case .weakKey: "Its certificate uses a weak key."
        case .nameConstraintViolation: "Its certificate names a site its authority may not certify."
        case .validityTooLong: "Its certificate is valid for longer than allowed."
        case .notPubliclyLogged: "Its certificate was not publicly logged."
        case .distrustedAuthority: "Its certificate is from an authority that is no longer trusted."
        case .selfSignedLocalNetwork: "Its certificate is self-signed on the local network."
        case .other: "Its certificate could not be verified."
        }
    }

    /// The error's name as Chrome prints it under its own page, and so as Arc shows it (for example
    /// `NET::ERR_CERT_AUTHORITY_INVALID`), from the reason whichever engine reported it. A reason Bow does not know
    /// has no Chrome name, so the line says the certificate is invalid in Chrome's words.
    public var errorName: String {
        switch error.reason {
        case .nameMismatch: "NET::ERR_CERT_COMMON_NAME_INVALID"
        case .dateInvalid: "NET::ERR_CERT_DATE_INVALID"
        case .untrustedAuthority: "NET::ERR_CERT_AUTHORITY_INVALID"
        case .containsErrors: "NET::ERR_CERT_CONTAINS_ERRORS"
        case .noRevocationMechanism: "NET::ERR_CERT_NO_REVOCATION_MECHANISM"
        case .unableToCheckRevocation: "NET::ERR_CERT_UNABLE_TO_CHECK_REVOCATION"
        case .revoked: "NET::ERR_CERT_REVOKED"
        case .invalid: "NET::ERR_CERT_INVALID"
        case .weakSignature: "NET::ERR_CERT_WEAK_SIGNATURE_ALGORITHM"
        case .nonUniqueName: "NET::ERR_CERT_NON_UNIQUE_NAME"
        case .weakKey: "NET::ERR_CERT_WEAK_KEY"
        case .nameConstraintViolation: "NET::ERR_CERT_NAME_CONSTRAINT_VIOLATION"
        case .validityTooLong: "NET::ERR_CERT_VALIDITY_TOO_LONG"
        case .notPubliclyLogged: "NET::ERR_CERTIFICATE_TRANSPARENCY_REQUIRED"
        case .distrustedAuthority: "NET::ERR_CERT_SYMANTEC_LEGACY"
        case .selfSignedLocalNetwork: "NET::ERR_CERT_SELF_SIGNED_LOCAL_NETWORK"
        case .other: "NET::ERR_CERT_INVALID"
        }
    }

    /// What the URL field shows while the tab shows this page: the address that failed, marked not secure, as
    /// Chrome's interstitial shows it, never the address of the page before (which the tab still reports, since the
    /// failed load never committed).
    public var addressLine: AddressLine {
        AddressLine(text: AddressDisplay.text(for: error.url), security: .notSecure)
    }

    /// Where the keyboard is when the page comes up over a pane, or when that pane gets focus.
    public enum KeyboardHolder: Equatable, Sendable {
        /// Nothing holds it, or the window itself does.
        case nothing
        /// The page under this one, in the same pane: it is hidden, so keys typed there would go nowhere visible.
        case coveredPage
        /// A field the person types in (the command bar, a rename in the sidebar).
        case textField
        /// Anything else: another pane's page, the sidebar, a button.
        case elsewhere
    }

    /// Whether the page takes the keyboard as it comes up over the focused pane, so Return presses Go back, as Chrome
    /// focuses its interstitial: from the hidden page under it or from nothing, never from a field the person types in
    /// or from anything else, and never over a pane that does not have focus.
    public static func takesKeyboard(from holder: KeyboardHolder, inFocusedPane: Bool) -> Bool {
        guard inFocusedPane else { return false }
        switch holder {
        case .nothing, .coveredPage: return true
        case .textField, .elsewhere: return false
        }
    }

    /// Whether a key press with `characters` presses Go back while the page has the keyboard: Return or the keypad's
    /// Enter, with no Command, Option or Control held (which belong to the menus).
    public static func pressesGoBack(characters: String?, commandOptionOrControl: Bool) -> Bool {
        guard !commandOptionOrControl, let characters else { return false }
        return characters == "\r" || characters == "\u{3}"
    }

    /// Where Go back takes the person.
    public enum GoBack: Equatable, Sendable {
        /// Back in the tab's history, to the page before the one that failed.
        case history
        /// The tab has no page to go back to: it closes, as Cmd+W closes it, and the window shows what it shows
        /// after a close (the start screen when the Space has no other tab).
        case closeTab
        /// The failed load has not settled yet: the page shows as soon as the engine asks, before the engine's own
        /// error page has taken its place in the tab's history, so whether there is a page to go back to is not known
        /// yet. Go back runs again once the tab stops loading.
        case waitForLoad
    }

    /// Where Go back goes for a tab that `isLoading` and `canGoBack` or not.
    public static func goBack(canGoBack: Bool, isLoading: Bool) -> GoBack {
        if isLoading { return .waitForLoad }
        return canGoBack ? .history : .closeTab
    }
}

/// Which of a window's tabs show the certificate error page. A tab shows it from the moment its top level page's
/// certificate fails until it starts another navigation (Go back, Reload, a new address), closes or its page's
/// process ends. An error that arrives for a navigation the tab has already left (the person went elsewhere while the
/// engine asked) shows nothing.
public struct CertificateErrorPages<Tab: Hashable> {
    /// The URL of each tab's latest navigation, as it started or was redirected.
    private var navigating: [Tab: URL] = [:]
    private var pages: [Tab: CertificateErrorPage] = [:]

    public init() {}

    /// The page `tab` shows, or nil.
    public func page(for tab: Tab) -> CertificateErrorPage? {
        pages[tab]
    }

    /// Whether no tab shows the page and none is tracked.
    public var isEmpty: Bool { pages.isEmpty && navigating.isEmpty }

    /// `tab` started a navigation to `url`, or was redirected there: any page it showed goes.
    public mutating func navigationStarted(_ tab: Tab, to url: URL) {
        navigating[tab] = url
        pages[tab] = nil
    }

    /// `tab` was redirected to `url`; its page, if any, stays.
    public mutating func redirected(_ tab: Tab, to url: URL) {
        navigating[tab] = url
    }

    /// `tab`'s top level page failed its certificate check with `error`. Returns true when the tab now shows the
    /// page: the error belongs to the tab's latest navigation (same host).
    @discardableResult
    public mutating func certificateFailed(_ tab: Tab, _ error: CertificateError) -> Bool {
        guard let errorHost = Self.host(error.url), Self.host(navigating[tab]) == errorHost else { return false }
        pages[tab] = CertificateErrorPage(error: error)
        return true
    }

    /// `tab`'s page process ended or the tab closed: it shows nothing and is forgotten.
    public mutating func forget(_ tab: Tab) {
        navigating[tab] = nil
        pages[tab] = nil
    }

    private static func host(_ url: URL?) -> String? {
        guard var host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }
}
