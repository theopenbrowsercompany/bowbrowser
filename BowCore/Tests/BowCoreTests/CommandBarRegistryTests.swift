import BowCore
import BowCoreTestSupport
import Foundation
import Testing

@Suite struct CommandBarRegistryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tabA = OpenTabInfo(
        id: UUID(), title: "A", url: URL(string: "https://a.test/")!,
        lastActive: Date(timeIntervalSince1970: 1_800_000_000))

    func registry(history: [HistoryEntryInfo] = [], timeout: Duration = .milliseconds(100)) async
        -> CommandBarRegistry
    {
        let registry = CommandBarRegistry(timeout: timeout)
        await registry.register(AddressInputProvider())
        await registry.register(OpenTabsProvider(source: StubOpenTabSource([tabA])))
        await registry.register(HistoryProvider(source: StubHistorySource(history)))
        return registry
    }

    @Test func mergesAddressTabsAndHistory() async {
        let history = [HistoryEntryInfo(title: "A archive", url: URL(string: "https://old.test/a")!, lastVisited: now)]
        let results = await registry(history: history).results(for: "a")
        #expect(results.map(\.title) == ["A", "A archive", "a"])
        #expect(results.first?.action == .switchToTab(tabA.id))
    }

    @Test func emptyQueryShowsOnlyOpenTabs() async {
        let results = await registry().results(for: "")
        #expect(results.map(\.title) == ["A"])
    }

    @Test func typedTextAlwaysOffersSearch() async {
        let results = await registry().results(for: "unmatched words")
        #expect(results.map(\.kind) == [.search])
        #expect(results.first?.url.absoluteString == AddressInput.searchURL + "unmatched%20words")
    }

    @Test func aSlowProviderDoesNotHoldUpTheOthers() async {
        let registry = await registry(timeout: .milliseconds(50))
        await registry.register(StubCommandBarProvider([], delayMilliseconds: 60_000, ignoresCancellation: true))
        let start = ContinuousClock.now
        let results = await registry.results(for: "a")
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(results.first?.title == "A")
    }

    @Test func updatesArriveAsProvidersAnswer() async {
        let registry = await registry(timeout: .seconds(2))
        let late = CommandBarCandidate(kind: .history, title: "Late page", url: URL(string: "https://late.test/")!)
        await registry.register(StubCommandBarProvider([late], delayMilliseconds: 200))
        var snapshots: [[String]] = []
        for await update in await registry.updates(for: "late") { snapshots.append(update.map(\.title)) }
        #expect(snapshots.count == 4)
        #expect(snapshots.last?.first == "Late page")
        #expect(snapshots.first?.contains("Late page") == false)
    }

    @Test func registryWithNoProvidersFinishesEmpty() async {
        let results = await CommandBarRegistry().results(for: "x")
        #expect(results.isEmpty)
    }

    @Test func addingAHistoryProviderLaterNeedsNoRankerChange() async {
        let registry = CommandBarRegistry()
        await registry.register(OpenTabsProvider(source: StubOpenTabSource([tabA])))
        let before = await registry.results(for: "a")
        await registry.register(
            HistoryProvider(
                source: StubHistorySource([
                    HistoryEntryInfo(title: "A page", url: URL(string: "https://p.test/")!, lastVisited: now)
                ])))
        let after = await registry.results(for: "a")
        #expect(before.map(\.title) == ["A"])
        #expect(after.map(\.title) == ["A", "A page"])
    }
}

@Suite struct AddressInputProviderTests {
    @Test func addressesGetALoadRowAndASearchRow() async {
        let candidates = await AddressInputProvider().candidates(for: " example.com ")
        #expect(candidates.map(\.kind) == [.navigation, .search])
        #expect(candidates.first?.url == AddressInput.resolve("example.com"))
    }

    @Test func blankInputGivesNothing() async {
        #expect(await AddressInputProvider().candidates(for: "  ").isEmpty)
    }
}
