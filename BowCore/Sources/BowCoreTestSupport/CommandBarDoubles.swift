import BowCore
import Foundation

/// Open tabs fixed by the test.
public struct StubOpenTabSource: OpenTabSource {
    public var tabs: [OpenTabInfo]

    public init(_ tabs: [OpenTabInfo] = []) {
        self.tabs = tabs
    }

    public func openTabs() async -> [OpenTabInfo] { tabs }
}

/// History entries fixed by the test. Like a real store it returns only entries whose title or
/// URL contains the query, newest first, up to the limit.
public struct StubHistorySource: HistorySource {
    public var entries: [HistoryEntryInfo]

    public init(_ entries: [HistoryEntryInfo] = []) {
        self.entries = entries
    }

    public func history(matching query: String, limit: Int) async -> [HistoryEntryInfo] {
        let needle = query.lowercased()
        let hits = entries.filter {
            $0.title.lowercased().contains(needle) || $0.url.absoluteString.lowercased().contains(needle)
        }
        return Array(hits.sorted { $0.lastVisited > $1.lastVisited }.prefix(limit))
    }
}

/// A provider that returns fixed candidates, optionally after a delay.
public struct StubCommandBarProvider: CommandBarProvider {
    public var result: [CommandBarCandidate]
    public var delayMilliseconds: Int?
    /// When true the provider sleeps without ever noticing cancellation.
    public var ignoresCancellation: Bool

    public init(_ result: [CommandBarCandidate], delayMilliseconds: Int? = nil, ignoresCancellation: Bool = false) {
        self.result = result
        self.delayMilliseconds = delayMilliseconds
        self.ignoresCancellation = ignoresCancellation
    }

    public func candidates(for query: String) async -> [CommandBarCandidate] {
        if let delayMilliseconds {
            if ignoresCancellation {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(delayMilliseconds)) {
                        continuation.resume()
                    }
                }
            } else {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
        }
        return result
    }
}
