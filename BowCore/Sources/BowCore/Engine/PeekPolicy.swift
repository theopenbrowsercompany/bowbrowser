import Foundation

// Peek: a link previewed in a card over the window instead of a tab, owned by the sidebar item it was opened from.
// These are the decisions (what opens a Peek, what the Peek's own page opens, where a promoted Peek goes, when a Peek
// closes, the card's size), as pure functions the window's Peek feature applies.

/// The two Peek settings, with Arc's defaults (both on, as Arc ships them: Settings > Links).
public struct PeekSettings: Equatable, Sendable {
    /// Arc's "Open a Peek window when clicking on links with Shift held". Off, a Shift-click opens a tab in the
    /// foreground, as before Peek.
    public var shiftClickOpensPeek: Bool
    /// Arc's "Open a Peek window when clicking on links to other sites": a link from a pinned tab or a Favorite that
    /// leaves its site opens in a Peek instead of taking the tab away from its site. Off, it opens as a new tab, so
    /// the tab still keeps its site (Arc's help: links then "always open in a New Tab").
    public var offSiteLinksOpenPeek: Bool

    public init(shiftClickOpensPeek: Bool = true, offSiteLinksOpenPeek: Bool = true) {
        self.shiftClickOpensPeek = shiftClickOpensPeek
        self.offSiteLinksOpenPeek = offSiteLinksOpenPeek
    }

    /// Arc's defaults: both on.
    public static let arcDefault = PeekSettings()
}

/// What the window knows when it decides about a Peek: the settings, and whether its Peek is already open.
public struct PeekContext: Equatable, Sendable {
    public var settings: PeekSettings
    /// True while the window shows a Peek. A window shows one Peek at a time.
    public var isOpen: Bool
    /// The link the asking tab already handed to Peek or to a new tab and that has not opened yet, or the address its
    /// open Peek was opened on. Chromium can ask about one click twice, and the second ask must open nothing more.
    public var handledURL: URL?

    public init(settings: PeekSettings = .arcDefault, isOpen: Bool = false, handledURL: URL? = nil) {
        self.settings = settings
        self.isOpen = isOpen
        self.handledURL = handledURL
    }

    public static let arcDefault = PeekContext()
}

/// Why a Peek closes, from the window's side.
public enum PeekCloseCause: Equatable, Sendable {
    /// Escape, the close button or a click on the dimmed page around the card.
    case dismissed
    /// The sidebar item it was opened from closed, unloaded, was archived or left the sidebar.
    case sourceGone
    /// The window shows another tab, or another Space.
    case sourceHidden
    /// The window is closing, or the app is quitting.
    case windowClosing
}

/// What a main frame navigation does (`PeekPolicy.navigationOutcome`).
public enum PeekNavigationOutcome: Equatable, Sendable {
    /// The tab goes to the address, as usual.
    case navigate
    /// The navigation is cancelled and the address opens in a Peek owned by the tab.
    case peek
    /// The navigation is cancelled and the address opens in a new tab, in the foreground, where the tab's new pages go.
    case newTab
    /// The navigation is cancelled and nothing opens: the same link was already handled (`PeekContext.handledURL`).
    case alreadyHandled
}

public enum PeekPolicy {
    /// Whether two addresses are on the same site for Peek: the same host, compared without case and without a
    /// leading `www.`. Arc compares hosts this way, so a link to another subdomain of the same site opens a Peek too.
    public static func isSameSite(_ first: URL, _ second: URL) -> Bool {
        guard let a = siteHost(first), let b = siteHost(second) else { return false }
        return a == b
    }

    private static func siteHost(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// What a main frame navigation of a tab does. A link the person clicked in a pinned tab or a Favorite, over http
    /// or https, to another site than the page it is on, never takes the tab away from its site: it opens in a Peek
    /// with the setting on, and as a new tab with it off (or while a Peek is already open), as Arc's help describes.
    /// Typed addresses, reloads, back and forward, form posts, script navigations without a click and same-site links
    /// navigate the tab as usual, and so does every navigation of a Today tab. Only a navigation's first ask may open
    /// a Peek: a server redirect of a link the tab already followed (a same-site "Sign in with Google" link that
    /// redirects to the provider) stays in the tab, so the flow finishes where it started.
    public static func navigationOutcome(
        _ navigation: EngineNavigation, currentURL: URL?, openerZone: PopupOpenerZone, context: PeekContext
    ) -> PeekNavigationOutcome {
        guard openerZone != .today, !navigation.isRedirect, navigation.transition == .link, navigation.isUserGesture,
            isWeb(navigation.url), let currentURL, isWeb(currentURL), !isSameSite(currentURL, navigation.url)
        else { return .navigate }
        if context.handledURL == navigation.url { return .alreadyHandled }
        return context.settings.offSiteLinksOpenPeek && !context.isOpen ? .peek : .newTab
    }

    private static func isWeb(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    /// What a Shift-click is answered: a Peek while the setting is on, else a tab in the foreground, as before Peek.
    /// With a Peek already open nothing more opens (a second Shift-click before the first Peek shows), so the
    /// window never stacks Peeks.
    public static func shiftClickDecision(context: PeekContext) -> PopupDecision {
        guard context.settings.shiftClickOpensPeek else { return .foregroundTab }
        return context.isOpen ? .block : .peek
    }

    /// Where the pages the Peek's own page opens go: a sign in popup to the popup panel and a request with no click
    /// nowhere, as from a tab; every other new page (a new tab link, a Cmd-click, a Shift-click) becomes a tab of the
    /// window, in the foreground or background as from a tab, never a second Peek.
    public static func decisionInPeek(for request: PopupRequest) -> PopupDecision {
        let decision = PopupPolicy.outcome(for: request, openerZone: .today, peek: PeekContext()).decision
        return decision == .peek ? PopupPolicy.plainLinkDecision : decision
    }

    /// Where a promoted Peek's tab goes: as a new page opened from its source would, right after a Today source, and
    /// at the top of Today for a pinned tab or a Favorite.
    public static func promotedPlacement(openerZone: PopupOpenerZone) -> PopupPlacement {
        openerZone == .today ? PopupPolicy.todayPlacement : PopupPolicy.pinnedOrFavoritePlacement
    }

    /// Whether the Peek's page may refuse to close at its leave prompt: only when the person dismissed it. Every other
    /// cause takes the Peek away whatever the page answers, since a Peek never outlives its source or shows over
    /// another tab; a page that stays is then unloaded.
    public static func pageMayStay(_ cause: PeekCloseCause) -> Bool {
        cause == .dismissed
    }
}

/// The Peek card's place in the page area: centered, leaving `margin` on every side and a toolbar row above the card
/// for its buttons, never larger than `maxCardWidth` wide.
public enum PeekLayout {
    /// The space between the card (with its toolbar row) and the page area's edges.
    public static let margin: Double = 40
    /// The height of the toolbar row above the card, which holds the Open as Tab and Close buttons.
    public static let toolbarHeight: Double = 32
    /// The widest the card grows on a large window.
    public static let maxCardWidth: Double = 1200
    /// The smallest card, kept on a very small window even if it then reaches the edges.
    public static let minCardSize = (width: 240.0, height: 160.0)

    /// The card's frame in a page area of `width` by `height` points, its origin at the bottom left (AppKit's).
    public static func cardFrame(width: Double, height: Double) -> (x: Double, y: Double, width: Double, height: Double)
    {
        let cardWidth = max(minCardSize.width, min(maxCardWidth, width - 2 * margin))
        let cardHeight = max(minCardSize.height, height - 2 * margin - toolbarHeight)
        let x = (width - cardWidth) / 2
        let y = max(0, (height - toolbarHeight - cardHeight) / 2)
        return (x, y, cardWidth, cardHeight)
    }
}
