import Foundation

// The certificate error page: what it says, which tabs show it, and where Go back goes.

/// The page a tab shows instead of a page whose certificate failed to verify, in plain words: a short title,
/// the host, what is wrong with its certificate, and the engine's error name for anyone who needs it. Its only
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
        switch error.code {
        case -200: "Its certificate belongs to a different site."
        case -201: "Its certificate has expired or is not valid yet."
        case -202: "Its certificate is not from an authority this Mac trusts."
        case -203: "Its certificate contains errors."
        case -204, -205: "Its certificate could not be checked for revocation."
        case -206: "Its certificate has been revoked by the authority that issued it."
        case -207: "Its certificate is not valid."
        case -208: "Its certificate uses a weak signature."
        case -210: "Its certificate names a site that is not unique."
        case -211: "Its certificate uses a weak key."
        case -212: "Its certificate names a site its authority may not certify."
        case -213: "Its certificate is valid for longer than allowed."
        case -214: "Its certificate was not publicly logged."
        case -217: "Its certificate is from an authority that is no longer trusted."
        case -219: "Its certificate is self-signed on the local network."
        default: "Its certificate could not be verified."
        }
    }

    /// The engine's name for the error, as Chrome prints it under its own page (for example
    /// `NET::ERR_CERT_AUTHORITY_INVALID`), or the bare code when it is not a known certificate error.
    public var errorName: String {
        let names: [Int: String] = [
            -200: "COMMON_NAME_INVALID", -201: "DATE_INVALID", -202: "AUTHORITY_INVALID", -203: "CONTAINS_ERRORS",
            -204: "NO_REVOCATION_MECHANISM", -205: "UNABLE_TO_CHECK_REVOCATION", -206: "REVOKED", -207: "INVALID",
            -208: "WEAK_SIGNATURE_ALGORITHM", -210: "NON_UNIQUE_NAME", -211: "WEAK_KEY",
            -212: "NAME_CONSTRAINT_VIOLATION", -213: "VALIDITY_TOO_LONG", -214: "TRANSPARENCY_REQUIRED",
            -217: "SYMANTEC_LEGACY", -219: "SELF_SIGNED_LOCAL_NETWORK",
        ]
        guard let name = names[error.code] else { return "Error \(error.code)" }
        return error.code == -214 ? "NET::ERR_CERTIFICATE_\(name)" : "NET::ERR_CERT_\(name)"
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
