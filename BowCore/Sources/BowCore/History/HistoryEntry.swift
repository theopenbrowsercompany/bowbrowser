import Foundation

/// One page in a profile's history: every visit to the same URL folds into one entry.
public struct HistoryEntry: Equatable, Sendable {
    public var url: URL
    /// The latest known page title, empty when none was seen.
    public var title: String
    public var visitCount: Int
    /// How many of the visits were typed or chosen in the address bar or command bar.
    public var typedCount: Int
    public var lastVisit: Date

    public init(url: URL, title: String = "", visitCount: Int = 1, typedCount: Int = 0, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
    }
}

/// A single visit to a page.
public struct HistoryVisit: Equatable, Sendable {
    public var time: Date
    public var transition: NavigationTransition

    public init(time: Date, transition: NavigationTransition) {
        self.time = time
        self.transition = transition
    }
}

public enum HistoryError: Error, Equatable, Sendable {
    /// SQLite reported a failure: its result code and message.
    case database(code: Int32, message: String)
    /// The history file was written by a newer version of Bow and is left untouched.
    case newerVersion
}
