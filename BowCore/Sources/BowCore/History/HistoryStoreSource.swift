import Foundation

/// Offers a profile's history to the command bar's `HistoryProvider`. A store that cannot be read offers nothing,
/// so a broken history file never breaks the bar.
public struct HistoryStoreSource: HistorySource {
    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    public func history(matching query: String, limit: Int) async -> [HistoryEntryInfo] {
        let entries = (try? store.search(query, limit: limit)) ?? []
        return entries.map { HistoryEntryInfo(title: $0.title, url: $0.url, lastVisited: $0.lastVisit) }
    }
}
