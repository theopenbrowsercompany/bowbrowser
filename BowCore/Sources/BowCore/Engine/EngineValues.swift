import Foundation

/// Stable identifier of a storage profile (one per space). The engine bridge mirrors it as a string.
public struct ProfileID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// The persistent profile that wraps the engine's global storage. It always exists.
    public static let `default`: ProfileID = "Default"

    /// Whether the ID can name a profile's folder: not empty, not `.` or `..`, and only ASCII
    /// letters, digits, `.`, `_` and `-`.
    public var isValid: Bool {
        guard !rawValue.isEmpty, rawValue != ".", rawValue != ".." else { return false }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII
                && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                    || scalar == "." || scalar == "_" || scalar == "-")
        }
    }

    public var description: String { rawValue }
}

/// Identifier the engine assigns to a tab when it is created. Unique for the life of the engine.
/// The engine bridge mirrors it as an unsigned 64 bit integer.
public struct TabID: RawRepresentable, Hashable, Sendable, ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(integerLiteral value: UInt64) {
        self.rawValue = value
    }

    public var description: String { String(rawValue) }
}

/// An immutable snapshot of a tab, as last pushed by the engine. Never computed on demand.
public struct EngineTabState: Equatable, Sendable {
    public var tabID: TabID
    /// The committed URL, or nil before anything has committed.
    public var url: URL?
    /// The page title, empty when the page has none yet.
    public var title: String
    public var faviconURL: URL?
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// True while the page plays sound. Engines that cannot tell (CEF 156 reports no audible state) leave it false.
    public var isAudible: Bool
    /// True while the page uses a camera (or captures the screen's video).
    public var isCapturingVideo: Bool
    /// True while the page uses a microphone (or captures the screen's audio).
    public var isCapturingAudio: Bool

    public init(
        tabID: TabID,
        url: URL? = nil,
        title: String = "",
        faviconURL: URL? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isAudible: Bool = false,
        isCapturingVideo: Bool = false,
        isCapturingAudio: Bool = false
    ) {
        self.tabID = tabID
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isAudible = isAudible
        self.isCapturingVideo = isCapturingVideo
        self.isCapturingAudio = isCapturingAudio
    }
}

/// Why a navigation started.
public enum NavigationTransition: Equatable, Sendable {
    /// A link click or script navigation in the page.
    case link
    /// Typed or chosen from the address bar or command bar, or loaded by the app.
    case typed
    case formSubmit
    case reload
    case backForward
    case other
}

/// One main frame navigation as the engine reports it.
public struct EngineNavigation: Equatable, Sendable {
    public var url: URL
    public var transition: NavigationTransition
    public var isUserGesture: Bool
    /// True when the engine asks about a server redirect of a navigation already under way, rather than the
    /// navigation's first ask. A redirect keeps the transition and gesture of the navigation it belongs to.
    public var isRedirect: Bool

    public init(
        url: URL, transition: NavigationTransition = .typed, isUserGesture: Bool = false, isRedirect: Bool = false
    ) {
        self.url = url
        self.transition = transition
        self.isUserGesture = isUserGesture
        self.isRedirect = isRedirect
    }
}

/// The answer to a navigation policy question. Decided synchronously in this version.
public enum NavigationPolicy: Equatable, Sendable {
    case allow
    case cancel
}

/// A failed navigation: the engine's network error code and its readable description.
public struct NavigationError: Error, Equatable, Sendable {
    public var code: Int
    public var description: String

    public init(code: Int, description: String) {
        self.code = code
        self.description = description
    }

    /// The engine's code for a navigation that ended without failing to load: it was stopped, replaced by a
    /// newer navigation, cancelled by the policy at a redirect, cut short by the tab closing or its render
    /// process ending, or it left no new page (a 204 response or a download).
    public static let abortedCode = -3

    /// True when the navigation was aborted rather than failed to load (see `abortedCode`). An app showing load
    /// errors should skip these: the page shown stays, or the navigation that replaced it reports its own result.
    public var isAborted: Bool { code == Self.abortedCode }
}

/// Where a page asked a new page to open.
public enum PopupDisposition: Equatable, Sendable {
    case foregroundTab
    case backgroundTab
    /// A sized popup window, such as an OAuth sign in.
    case popup
    case window
}

/// A window size in points that a page asked for when opening a popup.
public struct PopupSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A page asked to open a new tab or window.
public struct PopupRequest: Equatable, Sendable {
    public var targetURL: URL?
    public var disposition: PopupDisposition
    public var isUserGesture: Bool
    /// The size the page asked for, when it asked for one.
    public var requestedSize: PopupSize?
    /// The window features the page passed to `window.open` (position, size, whether it asked for a popup).
    public var windowFeatures: PopupWindowFeatures
    /// The modifier keys held at the click that opened the page, as far as the engine can tell: `target="_blank"`
    /// and Cmd-Shift-click arrive with the same disposition, so only these tell them apart. `.none` without a click.
    public var clickModifiers: PopupClickModifiers

    public init(
        targetURL: URL?,
        disposition: PopupDisposition,
        isUserGesture: Bool = false,
        requestedSize: PopupSize? = nil,
        windowFeatures: PopupWindowFeatures = PopupWindowFeatures(),
        clickModifiers: PopupClickModifiers = .none
    ) {
        self.targetURL = targetURL
        self.disposition = disposition
        self.isUserGesture = isUserGesture
        self.requestedSize = requestedSize
        self.windowFeatures = windowFeatures
        self.clickModifiers = clickModifiers
    }
}

/// Why a tab's render process ended.
public enum ProcessGoneReason: Equatable, Sendable {
    case crashed
    case killed
    case outOfMemory
    case launchFailed
    case other
}

/// What a find in page search has found so far.
public struct FindResult: Equatable, Sendable {
    /// How many matches the page holds, as counted so far.
    public var matchCount: Int
    /// The position of the active match, from 1 to `matchCount`, or 0 when there is none.
    public var activeMatch: Int
    /// True once the engine has finished counting; earlier results of the same search may count
    /// fewer matches.
    public var isFinal: Bool

    public init(matchCount: Int, activeMatch: Int, isFinal: Bool) {
        self.matchCount = matchCount
        self.activeMatch = activeMatch
        self.isFinal = isFinal
    }
}

/// Something that happened in a tab, pushed by the engine in order.
///
/// Main frame navigations go start, then any redirects, then commit, then finish or fail, and every started
/// navigation ends with finish or fail before the next one starts. A navigation the policy cancels before it
/// starts sends nothing. Same document navigations (fragments, `history.pushState`) and the error page the engine
/// shows after a failure send nothing either.
public enum TabEvent: Equatable, Sendable {
    /// The tab's snapshot changed; the payload is the new value of `EngineTab.state`.
    case stateChanged(EngineTabState)
    case didStartNavigation(EngineNavigation)
    /// The server redirected the navigation; the payload's URL is the new one.
    case didRedirect(EngineNavigation)
    /// The new page committed: the address the tab shows is now the payload's URL.
    case didCommit(EngineNavigation)
    /// The page finished loading. `httpStatus` is 0 when there is none: a scheme without one, or a page
    /// restored from history that finishes when loading stops.
    case didFinish(EngineNavigation, httpStatus: Int)
    /// The navigation failed or was aborted (`NavigationError.isAborted`).
    case didFail(EngineNavigation, NavigationError)
    /// The page opened a new tab or window. This only informs the app: the engine opens the page itself, in a
    /// popup window of its own, so it keeps `window.opener`; the app must not open `targetURL` again.
    case popupRequested(PopupRequest)
    case fullscreenChanged(Bool)
    /// The render process ended; the page is gone until the tab reloads.
    case renderProcessGone(ProcessGoneReason)
    /// A search started by `EngineTab.find` found matches or moved the active one. One search can
    /// report several times as the engine counts; the last has `isFinal`.
    case findResult(FindResult)
    /// The page was unloaded by `EngineTab.unload()`: its browser is gone and the tab is closed, but the app keeps
    /// its model to load it again later. Sent once, as the tab's last event, instead of `closed`.
    case unloaded
    /// The page has been destroyed, whoever closed it: the app, quitting, or the page itself
    /// (`EngineTab.closeReason` says which). Sent once, as the tab's last event (a tab that was unloaded sends
    /// `unloaded` instead).
    case closed
}

/// Why a tab closed, read from `EngineTab.closeReason` once it has.
public enum TabCloseReason: Equatable, Sendable {
    /// The app closed it with `EngineTab.close()`.
    case app
    /// The engine closed it without the app asking: the page called `window.close()`, or the engine could not
    /// create the page at all. A window removes such a tab from its list.
    case page
    /// Quitting the engine closed it.
    case quit
}

/// Errors the engine reports to the app.
public enum EngineError: Error, Equatable, Sendable {
    /// A profile with this ID already exists.
    case profileExists(ProfileID)
    /// The ID cannot name a folder: see `ProfileID.isValid`.
    case invalidProfileID(ProfileID)
}
