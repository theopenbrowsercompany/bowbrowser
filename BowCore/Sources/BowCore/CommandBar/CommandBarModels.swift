import Foundation

/// One thing a provider offers for the text in the command bar, before ranking.
public struct CommandBarCandidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A tab that is already open; choosing it switches to that tab.
        case openTab(UUID)
        /// A page visited before.
        case history
        /// The address the person typed, to load as is.
        case navigation
        /// A web search for the typed text.
        case search
    }

    public var kind: Kind
    public var title: String
    public var url: URL
    /// When the page was last visited or the tab last used, for breaking ties.
    public var lastUsed: Date?

    public init(kind: Kind, title: String, url: URL, lastUsed: Date? = nil) {
        self.kind = kind
        self.title = title
        self.url = url
        self.lastUsed = lastUsed
    }
}

/// What choosing a result does.
public enum CommandBarAction: Equatable, Sendable {
    /// Bring an open tab to the front instead of opening a new one.
    case switchToTab(UUID)
    /// Load this address (in a new tab or the current one, as the bar was opened).
    case navigate(URL)
}

/// One row in the command bar after ranking.
public struct CommandBarResult: Equatable, Sendable, Identifiable {
    public var kind: CommandBarCandidate.Kind
    public var title: String
    public var url: URL
    public var action: CommandBarAction

    /// Stable across keystrokes so the view can keep selection on the same row.
    public var id: String {
        switch kind {
        case .openTab(let tab): "tab:\(tab.uuidString)"
        case .history: "history:\(url.absoluteString)"
        case .navigation: "navigate:\(url.absoluteString)"
        case .search: "search:\(url.absoluteString)"
        }
    }

    public init(candidate: CommandBarCandidate) {
        kind = candidate.kind
        title = candidate.title
        url = candidate.url
        switch candidate.kind {
        case .openTab(let tab): action = .switchToTab(tab)
        case .history, .navigation, .search: action = .navigate(candidate.url)
        }
    }
}

/// A source of candidates for the command bar. Providers are registered once and asked again on
/// every keystroke, so they must answer from memory or an index and honor task cancellation.
public protocol CommandBarProvider: Sendable {
    /// Candidates for `query`, which is not trimmed and may be empty (a bar opened with Cmd+T).
    /// A provider may return loosely related items: the ranker drops those that do not match.
    func candidates(for query: String) async -> [CommandBarCandidate]
}

/// An open tab as the command bar sees it. The tab model adapts its tabs to this shape.
public struct OpenTabInfo: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var lastActive: Date

    public init(id: UUID, title: String, url: URL, lastActive: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.lastActive = lastActive
    }
}

/// A visited page as the command bar sees it. The history store adapts its entries to this shape.
public struct HistoryEntryInfo: Equatable, Sendable {
    public var title: String
    public var url: URL
    public var lastVisited: Date

    public init(title: String, url: URL, lastVisited: Date) {
        self.title = title
        self.url = url
        self.lastVisited = lastVisited
    }
}

/// Supplies the tabs open in the window the bar belongs to.
public protocol OpenTabSource: Sendable {
    func openTabs() async -> [OpenTabInfo]
}

/// Supplies visited pages that may match the typed text.
public protocol HistorySource: Sendable {
    func history(matching query: String, limit: Int) async -> [HistoryEntryInfo]
}
