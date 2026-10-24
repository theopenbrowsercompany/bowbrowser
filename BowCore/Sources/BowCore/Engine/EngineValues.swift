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
    /// True while the page plays sound, as the page's media elements report it.
    public var isAudible: Bool
    /// True while the page uses a camera (or captures the screen's video).
    public var isCapturingVideo: Bool
    /// True while the page uses a microphone (or captures the screen's audio).
    public var isCapturingAudio: Bool
    /// True once the person edited a form field in one of the page's frames, by any means (typing, pasting,
    /// dropping, dictating, autofill, choosing a file), until the main frame commits a new document.
    public var hasEditedForm: Bool

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
        isCapturingAudio: Bool = false,
        hasEditedForm: Bool = false
    ) {
        self.hasEditedForm = hasEditedForm
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

/// A failed navigation: why it failed, in the engine's terms mapped to Bow's, and the engine's own readable text
/// for it (for logs, never shown as the reason).
public struct NavigationError: Error, Equatable, Sendable {
    /// Why a navigation ended without loading a page. Each engine maps its own error codes to these.
    public enum Reason: Hashable, Sendable, CaseIterable {
        /// The navigation ended without failing to load: it was stopped, replaced by a newer navigation, cancelled
        /// by the policy at a redirect, cut short by the tab closing or its page's process ending, or it left no
        /// new page (a 204 response or a download).
        case aborted
        /// The host's name did not resolve.
        case nameNotResolved
        /// The server could not be reached or refused the connection.
        case cannotConnect
        /// The connection dropped or the server closed it before answering.
        case connectionLost
        /// The server took too long to answer.
        case timedOut
        /// The Mac is not connected to the internet.
        case offline
        /// The server's certificate failed to verify (the certificate question comes first, see `CertificateError`).
        case certificate
        /// The address is malformed or names a scheme the engine cannot load.
        case badAddress
        /// The load was blocked, by the engine, a content rule or the server's response policy.
        case blocked
        /// Any other failure.
        case other
    }

    public var reason: Reason
    public var description: String

    public init(reason: Reason, description: String) {
        self.reason = reason
        self.description = description
    }

    /// True when the navigation was aborted rather than failed to load (`Reason.aborted`). An app showing load
    /// errors should skip these: the page shown stays, or the navigation that replaced it reports its own result.
    public var isAborted: Bool { reason == .aborted }
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

/// Why the process running a tab's page ended. Each engine maps its own termination reasons to these.
public enum ProcessGoneReason: Hashable, Sendable, CaseIterable {
    /// The process crashed.
    case crashed
    /// Something outside the engine killed it (the system, or a person in Activity Monitor).
    case killed
    /// It ran out of memory, or the engine ended it for using more memory than its limit.
    case outOfMemory
    /// The engine ended it for using too much CPU in the background.
    case exceededCPULimit
    /// The app asked the engine to end it.
    case requestedByApp
    /// It could not start.
    case launchFailed
    /// Any other reason.
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
    /// The page opened a popup window (`PopupDecision.window`). This only informs the app: the page is already on
    /// its way into that window, connected to its opener (`window.opener`), so the app must not open `targetURL`
    /// again.
    case popupRequested(PopupRequest)
    case fullscreenChanged(Bool)
    /// The process running the page ended; the page is gone until the tab reloads.
    case renderProcessGone(ProcessGoneReason)
    /// A search started by `EngineTab.find` found matches or moved the active one. One search can
    /// report several times as the engine counts; the last has `isFinal`.
    case findResult(FindResult)
    /// The page's status text changed: the address of the link under the pointer, or "" once the pointer has left
    /// every link. Sent only when the text changes.
    case statusTextChanged(String)
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
