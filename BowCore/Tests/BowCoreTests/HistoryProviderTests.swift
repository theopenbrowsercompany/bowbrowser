import BowCore
import BowCoreTestSupport
import Foundation
import Testing

/// The history store behind the command bar's history provider, ranked against open tabs.
@Suite struct HistoryProviderTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func store() throws -> HistoryStore {
        try HistoryStore(profileID: "work", isPersistent: false, directory: FileManager.default.temporaryDirectory)
    }

    func registry(_ store: HistoryStore, tabs: [OpenTabInfo] = []) async -> CommandBarRegistry {
        let registry = CommandBarRegistry(timeout: .seconds(3600))
        await registry.register(OpenTabsProvider(source: StubOpenTabSource(tabs)))
        await registry.register(HistoryProvider(source: HistoryStoreSource(store: store)))
        return registry
    }

    @Test func offersStoredPagesThatMatchTheQuery() async throws {
        let store = try store()
        try store.recordVisit(url: URL(string: "https://swift.org/blog")!, title: "Swift blog", at: now)
        try store.recordVisit(url: URL(string: "https://example.com/")!, title: "Example", at: now)
        let results = await registry(store).results(for: "swift")
        #expect(results.map(\.title) == ["Swift blog"])
        #expect(results.first?.kind == .history)
        #expect(results.first?.action == .navigate(URL(string: "https://swift.org/blog")!))
    }

    @Test func blankQueryOffersNoHistory() async throws {
        let store = try store()
        try store.recordVisit(url: URL(string: "https://swift.org/")!, title: "Swift", at: now)
        #expect(await registry(store).results(for: "  ").isEmpty)
    }

    @Test func openTabRanksAboveHistoryWithTheSameMatch() async throws {
        let store = try store()
        try store.recordVisit(url: URL(string: "https://swift.org/old")!, title: "Swift old", at: now)
        let tab = OpenTabInfo(
            id: UUID(), title: "Swift open", url: URL(string: "https://swift.org/open")!, lastActive: now)
        let results = await registry(store, tabs: [tab]).results(for: "swift")
        #expect(results.map(\.title) == ["Swift open", "Swift old"])
    }

    @Test func openTabHidesTheHistoryEntryOfTheSameURL() async throws {
        let store = try store()
        let url = URL(string: "https://swift.org/open")!
        try store.recordVisit(url: url, title: "Swift", at: now)
        let tab = OpenTabInfo(id: UUID(), title: "Swift", url: url, lastActive: now)
        let results = await registry(store, tabs: [tab]).results(for: "swift")
        #expect(results.map(\.kind) == [.openTab(tab.id)])
    }

    @Test func historyFollowsTheStoreSearchRankingForMoreVisits() async throws {
        let store = try store()
        let once = URL(string: "https://swift.org/once")!
        let often = URL(string: "https://swift.org/often")!
        try store.recordVisit(url: often, title: "Swift often", at: now.addingTimeInterval(-100))
        try store.recordVisit(url: often, title: "Swift often", at: now.addingTimeInterval(-90))
        try store.recordVisit(url: once, title: "Swift once", at: now)
        let infos = await HistoryStoreSource(store: store).history(matching: "swift", limit: 10)
        #expect(infos.map(\.url) == [often, once])
    }

    @Test func limitCapsTheStoreAnswer() async throws {
        let store = try store()
        for index in 0..<5 {
            try store.recordVisit(url: URL(string: "https://swift.org/\(index)")!, title: "Swift", at: now)
        }
        #expect(await HistoryStoreSource(store: store).history(matching: "swift", limit: 2).count == 2)
    }
}
