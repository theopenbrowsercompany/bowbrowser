import BowCore
import BowCoreTestSupport
import Foundation
import Testing

@Suite struct CommandBarRegistryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tabA = OpenTabInfo(
        id: UUID(), title: "A", url: URL(string: "https://a.test/")!,
        lastActive: Date(timeIntervalSince1970: 1_800_000_000))

    func registry(history: [HistoryEntryInfo] = [], timeout: Duration = .seconds(3600)) async
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

    /// The registry's deadline is a gate the test opens after the fast providers have answered, and
    /// the slow provider ignores cancellation, so the result never depends on how fast the machine is.
    /// A regression hangs the test until the time limit.
    @Test(.timeLimit(.minutes(1))) func aSlowProviderDoesNotHoldUpTheOthers() async {
        let deadline = Gate()
        let registry = CommandBarRegistry(sleep: { _ in await deadline.wait() })
        await registry.register(AddressInputProvider())
        await registry.register(OpenTabsProvider(source: StubOpenTabSource([tabA])))
        await registry.register(HistoryProvider(source: StubHistorySource([])))
        let stuck = Gate()
        await registry.register(GatedProvider([], gate: stuck))
        var snapshots: [[String]] = []
        for await update in await registry.updates(for: "a") {
            snapshots.append(update.map(\.title))
            if snapshots.count == 3 { await deadline.open() }
        }
        // Three fast providers and the timed out one each count as an answer.
        #expect(snapshots.count == 4)
        #expect(snapshots.last?.first == "A")
        await stuck.open()  // lets the abandoned provider finish, so nothing leaks
    }

    @Test(.timeLimit(.minutes(1))) func updatesArriveAsProvidersAnswer() async {
        let registry = await registry(timeout: .seconds(3600))
        let late = CommandBarCandidate(kind: .history, title: "Late page", url: URL(string: "https://late.test/")!)
        let gate = Gate()
        await registry.register(GatedProvider([late], gate: gate))
        var snapshots: [[String]] = []
        for await update in await registry.updates(for: "late") {
            snapshots.append(update.map(\.title))
            // Release the late provider only once every fast provider has been heard.
            if snapshots.count == 3 { await gate.open() }
        }
        #expect(snapshots.count == 4)
        #expect(snapshots.last?.first == "Late page")
        #expect(snapshots.first?.contains("Late page") == false)
    }

    @Test func registryWithNoProvidersFinishesEmpty() async {
        let registry = CommandBarRegistry()
        var updates = 0
        for await update in await registry.updates(for: "x") {
            updates += 1
            #expect(update.isEmpty)
        }
        #expect(updates == 1)
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

/// A one shot latch: waiters resume when it opens.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A provider that answers only after its gate opens.
private struct GatedProvider: CommandBarProvider {
    let result: [CommandBarCandidate]
    let gate: Gate

    init(_ result: [CommandBarCandidate], gate: Gate) {
        self.result = result
        self.gate = gate
    }

    func candidates(for query: String) async -> [CommandBarCandidate] {
        await gate.wait()
        return result
    }
}
