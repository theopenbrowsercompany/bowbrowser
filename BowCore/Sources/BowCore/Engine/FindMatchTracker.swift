/// Turns the engine's match count and the person's find steps into the "n of m" a find bar shows, for an engine
/// that counts matches but cannot be trusted with its own active index (WebKit).
///
/// It follows the `EngineTab.find(_:forward:matchCase:)` contract: other text, another match case, or the first
/// find after a stop (or after `pageChanged()`) starts a new search; the same text again steps forward or back;
/// empty text stops. Every call to `find` returns what the engine wiring must do (`Action`) and the result to send
/// as `TabEvent.findResult`, if any. The wiring reports the engine's count with `counted(text:count:)`.
///
/// Known approximation: a new search starts at match 1, while WebKit's own find starts from the current selection.
/// Other WebKit browsers track from 1 the same way.
///
/// The type holds no engine state, so the CEF adapter does not use it: Chromium reports its own correct index.
public struct FindMatchTracker: Equatable, Sendable {
    /// What the engine wiring does for one `find` call.
    public enum Action: Equatable, Sendable {
        /// Start a new search for `text` and count its matches, reporting the count with `counted(text:count:)`.
        case startSearch(text: String, matchCase: Bool)
        /// Move the engine's selection to the next or previous match.
        case step(forward: Bool)
        /// End the search and clear the highlights.
        case stop
    }

    /// The outcome of one `find` call.
    public struct Update: Equatable, Sendable {
        public var action: Action
        /// The result to send, or nil when there is nothing to show yet (a new search before its count arrives,
        /// or a stop, where the bar clears its count).
        public var result: FindResult?
    }

    private struct Search: Equatable, Sendable {
        var text: String
        var matchCase: Bool
        /// The engine's count, nil until it arrives.
        var count: Int?
        /// The active match, from 1 to `count` (0 when there are none); meaningful once `count` is known.
        var active = 1
        /// Net steps taken before the count arrived, forward positive.
        var pendingSteps = 0
    }

    private var search: Search?

    public init() {}

    /// Handles a find request.
    public mutating func find(_ text: String, forward: Bool, matchCase: Bool) -> Update {
        if text.isEmpty {
            search = nil
            return Update(action: .stop, result: nil)
        }
        guard var current = search, current.text == text, current.matchCase == matchCase else {
            search = Search(text: text, matchCase: matchCase)
            return Update(action: .startSearch(text: text, matchCase: matchCase), result: nil)
        }
        let delta = forward ? 1 : -1
        guard let count = current.count else {
            current.pendingSteps += delta
            search = current
            return Update(action: .step(forward: forward), result: nil)
        }
        current.active = Self.wrap(current.active, by: delta, count: count)
        search = current
        return Update(action: .step(forward: forward), result: Self.result(current))
    }

    /// Takes the engine's count for the search for `text`. Returns the result to send, or nil when the count is
    /// stale (another word is being searched, or no search is running).
    public mutating func counted(text: String, count: Int) -> FindResult? {
        guard var current = search, current.text == text else { return nil }
        let count = max(count, 0)
        if current.count == nil {
            current.active = Self.wrap(1, by: current.pendingSteps, count: count)
            current.pendingSteps = 0
        } else {
            current.active = count == 0 ? 0 : min(max(current.active, 1), count)
        }
        current.count = count
        search = current
        return Self.result(current)
    }

    /// The tab committed a new main frame document. The last result stays shown; the next find with the same text
    /// starts a new search that counts again and starts at 1.
    public mutating func pageChanged() {
        search = nil
    }

    private static func wrap(_ active: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let offset = (active - 1 + delta) % count
        return (offset + count) % count + 1
    }

    private static func result(_ search: Search) -> FindResult {
        FindResult(matchCount: search.count ?? 0, activeMatch: search.active, isFinal: true)
    }
}
