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

    public init(
        tabID: TabID,
        url: URL? = nil,
        title: String = "",
        faviconURL: URL? = nil,
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false
    ) {
        self.tabID = tabID
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
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

    public init(url: URL, transition: NavigationTransition = .typed, isUserGesture: Bool = false) {
        self.url = url
        self.transition = transition
        self.isUserGesture = isUserGesture
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

    public init(
        targetURL: URL?,
        disposition: PopupDisposition,
        isUserGesture: Bool = false,
        requestedSize: PopupSize? = nil
    ) {
        self.targetURL = targetURL
        self.disposition = disposition
        self.isUserGesture = isUserGesture
        self.requestedSize = requestedSize
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

/// Something that happened in a tab, pushed by the engine in order.
public enum TabEvent: Equatable, Sendable {
    /// The tab's snapshot changed; the payload is the new value of `EngineTab.state`.
    case stateChanged(EngineTabState)
    case didStartNavigation(EngineNavigation)
    case didRedirect(EngineNavigation)
    case didCommit(EngineNavigation)
    case didFinish(EngineNavigation, httpStatus: Int)
    case didFail(EngineNavigation, NavigationError)
    case popupRequested(PopupRequest)
    case fullscreenChanged(Bool)
    case renderProcessGone(ProcessGoneReason)
}

/// Errors the engine reports to the app.
public enum EngineError: Error, Equatable, Sendable {
    /// A profile with this ID already exists.
    case profileExists(ProfileID)
}
