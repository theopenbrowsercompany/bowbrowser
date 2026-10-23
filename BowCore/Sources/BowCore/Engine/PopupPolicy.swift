import Foundation

// Where a page's new page goes: the decision and, for a tab, where the tab lands. A pure function,
// so the window applies the result and the rules stay easy to change and test.

/// Where the page that opened a new page lives in the sidebar.
public enum PopupOpenerZone: Equatable, Sendable {
    case pinned
    case favorite
    case today
}

/// The modifier keys held during the click that opened the new page.
public struct PopupClickModifiers: Equatable, Sendable {
    public var command: Bool
    public var shift: Bool

    public init(command: Bool = false, shift: Bool = false) {
        self.command = command
        self.shift = shift
    }

    public static let none = PopupClickModifiers()
}

/// Where a new tab is inserted. The window applies it; the policy never touches the sidebar.
public enum PopupPlacement: Equatable, Sendable {
    /// Right after the tab that opened it, in Today.
    case afterOpener
    /// At the top of Today.
    case topOfToday
}

/// What to do with a request: the decision and, when it is a tab, where the tab goes.
public struct PopupOutcome: Equatable, Sendable {
    public var decision: PopupDecision
    /// Nil unless `decision` is a tab.
    public var placement: PopupPlacement?

    public init(decision: PopupDecision, placement: PopupPlacement? = nil) {
        self.decision = decision
        self.placement = placement
    }
}

/// An identity provider's sign in pages: every page on `host` (compared without case), or only those whose path
/// starts with `pathPrefix` at a path segment boundary.
public struct IdentityProviderPattern: Equatable, Sendable {
    public var host: String
    public var pathPrefix: String?

    public init(host: String, pathPrefix: String? = nil) {
        self.host = host.lowercased()
        self.pathPrefix = pathPrefix
    }

    /// `host` must already be lowercased.
    func matches(host: String, path: String) -> Bool {
        guard host == self.host else { return false }
        guard let pathPrefix else { return true }
        return path == pathPrefix || path.hasPrefix(pathPrefix + "/")
    }
}

/// The rules, as named values so each is easy to change.
public enum PopupPolicy {
    /// A plain `target="_blank"` link, or a `window.open` after a click: shown at once, as Chromium and Arc do.
    public static let plainLinkDecision = PopupDecision.foregroundTab
    /// Cmd-click and middle click: the tab opens behind the shown one.
    public static let commandDecision = PopupDecision.backgroundTab
    /// Cmd-Shift-click.
    public static let commandShiftDecision = PopupDecision.foregroundTab
    /// Shift-click, the future Peek gesture: a foreground tab until Peek exists.
    public static let shiftDecision = PopupDecision.foregroundTab
    /// A request with no user gesture.
    public static let noGestureDecision = PopupDecision.block
    /// A sized `window.open` from a click (a sign in popup) opens in a panel attached to the opener's window, as Arc
    /// shows login popups in a small window of their own instead of a tab; it keeps `window.opener`.
    public static let sizedPopupDecision = PopupDecision.popupPanel
    /// A plain click (no modifier) that opens an identity provider's sign in page opens it in the panel too, sized or
    /// not: Arc keeps a list of identity provider pages that stay in a popup. A modified click still opens a tab.
    public static let identityProviderDecision = PopupDecision.popupPanel
    /// The identity providers' sign in pages: a host and, when set, the path the sign in pages start with.
    public static let identityProviders: [IdentityProviderPattern] = [
        IdentityProviderPattern(host: "accounts.google.com"),
        IdentityProviderPattern(host: "login.microsoftonline.com"),
        IdentityProviderPattern(host: "appleid.apple.com"),
        IdentityProviderPattern(host: "github.com", pathPrefix: "/login/oauth"),
    ]

    /// True when `url` is an identity provider's sign in page (`identityProviders`), over https only.
    public static func isIdentityProvider(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return identityProviders.contains { $0.matches(host: host, path: url.path) }
    }

    /// True when `request` opens in a popup panel: a sized `window.open` from a click, or a plain click opening an
    /// identity provider's sign in page. Never without a click.
    public static func opensPanel(_ request: PopupRequest) -> Bool {
        guard request.isUserGesture else { return false }
        if isSized(request) { return true }
        return request.clickModifiers == .none && isIdentityProvider(request.targetURL)
    }
    /// Where a tab opened from Today goes.
    public static let todayPlacement = PopupPlacement.afterOpener
    /// Where a tab opened from a pinned tab or a Favorite goes.
    public static let pinnedOrFavoritePlacement = PopupPlacement.topOfToday

    /// The modifiers come from the request's click (`PopupRequest.clickModifiers`), which the engine's disposition
    /// alone cannot tell apart (`target="_blank"` and Cmd-Shift-click both arrive as a foreground tab).
    public static func outcome(for request: PopupRequest, openerZone: PopupOpenerZone) -> PopupOutcome {
        let modifiers = request.clickModifiers
        guard request.isUserGesture else { return PopupOutcome(decision: noGestureDecision) }
        if isSized(request) { return PopupOutcome(decision: sizedPopupDecision) }
        if opensPanel(request) { return PopupOutcome(decision: identityProviderDecision) }

        let decision: PopupDecision
        switch (modifiers.command, modifiers.shift) {
        case (true, true): decision = commandShiftDecision
        case (false, true): decision = shiftDecision
        case (true, false): decision = commandDecision
        default: decision = plainLinkDecision
        }
        let placement: PopupPlacement
        switch openerZone {
        case .today: placement = todayPlacement
        case .pinned, .favorite: placement = pinnedOrFavoritePlacement
        }
        return PopupOutcome(decision: decision, placement: placement)
    }

    private static func isSized(_ request: PopupRequest) -> Bool {
        request.requestedSize != nil
            || request.windowFeatures.width != nil
            || request.windowFeatures.height != nil
            || request.windowFeatures.isPopup
            || request.disposition == .popup
    }
}
