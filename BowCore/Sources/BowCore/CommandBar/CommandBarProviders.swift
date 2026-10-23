import Foundation

/// The typed text itself: an address to load, and a search for it. Sends everything through
/// `AddressInput`, so the bar and the address field never disagree about what text means.
public struct AddressInputProvider: CommandBarProvider {
    public init() {}

    public func candidates(for query: String) async -> [CommandBarCandidate] {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let interpretation = AddressInput.interpret(input)
        switch interpretation {
        case .empty:
            return []
        case .url(let url), .host(let url):
            var result = [CommandBarCandidate(kind: .navigation, title: input, url: url)]
            // An address can still be a search, so keep that choice available below it.
            result.append(CommandBarCandidate(kind: .search, title: input, url: AddressInput.searchURL(for: input)))
            return result
        case .search(let url):
            return [CommandBarCandidate(kind: .search, title: input, url: url)]
        }
    }
}

/// Tabs that are already open.
public struct OpenTabsProvider: CommandBarProvider {
    private let source: any OpenTabSource

    public init(source: any OpenTabSource) {
        self.source = source
    }

    public func candidates(for query: String) async -> [CommandBarCandidate] {
        await source.openTabs().map {
            CommandBarCandidate(kind: .openTab($0.id), title: $0.title, url: $0.url, lastUsed: $0.lastActive)
        }
    }
}

/// Pages visited before.
public struct HistoryProvider: CommandBarProvider {
    private let source: any HistorySource
    private let limit: Int

    public init(source: any HistorySource, limit: Int = 20) {
        self.source = source
        self.limit = limit
    }

    public func candidates(for query: String) async -> [CommandBarCandidate] {
        // Blank input shows open tabs only; history appears once there is something to match.
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return await source.history(matching: query, limit: limit).map {
            CommandBarCandidate(kind: .history, title: $0.title, url: $0.url, lastUsed: $0.lastVisited)
        }
    }
}
