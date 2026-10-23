import BowCore
import Foundation
import Testing

/// One test per ranking rule of `CommandBarRanker`.
@Suite struct CommandBarRankerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ranker = CommandBarRanker(maxResults: 8)

    func tab(_ title: String, _ url: String, age: Double = 0) -> CommandBarCandidate {
        CommandBarCandidate(
            kind: .openTab(UUID()), title: title, url: URL(string: url)!, lastUsed: now.addingTimeInterval(-age))
    }

    func page(_ title: String, _ url: String, age: Double = 0) -> CommandBarCandidate {
        CommandBarCandidate(
            kind: .history, title: title, url: URL(string: url)!, lastUsed: now.addingTimeInterval(-age))
    }

    func typed(_ text: String) -> [CommandBarCandidate] {
        let address = AddressInput.interpret(text)
        let url = address.url!
        return address.isAddress
            ? [
                CommandBarCandidate(kind: .navigation, title: text, url: url),
                CommandBarCandidate(kind: .search, title: text, url: AddressInput.searchURL(for: text)),
            ] : [CommandBarCandidate(kind: .search, title: text, url: url)]
    }

    func titles(_ results: [CommandBarResult]) -> [String] { results.map(\.title) }

    @Test func exactURLMatchBeatsEverythingIncludingTheTypedAddress() {
        let exact = tab("Docs", "https://example.com/docs")
        let results = ranker.rank(
            query: "example.com/docs",
            candidatesByProvider: [
                typed("example.com/docs"), [page("Example", "https://example.com/docs/intro"), exact],
            ])
        #expect(results.first?.title == "Docs")
        #expect(results.first?.action == .switchToTab(tabID(exact)))
    }

    @Test func urlPrefixBeatsTitlePrefixBeatsWordPrefixBeatsSubstring() {
        let results = ranker.rank(
            query: "ex",
            candidatesByProvider: [
                [
                    page("Contains", "https://a.test/vexed"),
                    page("Word", "https://b.test/x"),
                    page("Ex title", "https://c.test/"),
                    page("Other", "https://ex.test/"),
                ]
            ])
        // "Word" does not match "ex" at all, so it is dropped.
        #expect(titles(results) == ["Other", "Ex title", "Contains"])
    }

    @Test func wordPrefixInTitleBeatsSubstring() {
        let results = ranker.rank(
            query: "guide",
            candidatesByProvider: [
                [
                    page("Swiftguide", "https://a.test/"),
                    page("The swift guide", "https://b.test/"),
                ]
            ])
        #expect(titles(results.filter { $0.kind == .history }) == ["The swift guide", "Swiftguide"])
    }

    @Test func everyTypedWordMustMatch() {
        let results = ranker.rank(
            query: "swift guide",
            candidatesByProvider: [
                [
                    page("Swift guide", "https://a.test/"),
                    page("Swift news", "https://b.test/"),
                ]
            ])
        #expect(titles(results.filter { $0.kind == .history }) == ["Swift guide"])
    }

    @Test func textMatchingNothingDropsTabsAndPages() {
        let results = ranker.rank(
            query: "zzz",
            candidatesByProvider: [
                typed("zzz"), [tab("Inbox", "https://mail.test/"), page("News", "https://news.test/")],
            ])
        #expect(results.count == 1)
        #expect(results.first?.kind == .search)
    }

    @Test func matchingIgnoresCaseAndAccents() {
        let results = ranker.rank(
            query: "CAFE",
            candidatesByProvider: [[page("Café Menu", "https://c.test/")]])
        #expect(titles(results) == ["Café Menu"])
    }

    @Test func tabBeatsHistoryWithTheSameMatch() {
        let results = ranker.rank(
            query: "news",
            candidatesByProvider: [
                [page("News", "https://p.test/", age: 0)], [tab("News", "https://t.test/", age: 5000)],
            ])
        #expect(results.map(\.url.absoluteString) == ["https://t.test/", "https://p.test/"])
    }

    @Test func typedAddressBeatsPrefixMatches() {
        let results = ranker.rank(
            query: "github.com",
            candidatesByProvider: [typed("github.com"), [page("GitHub Docs", "https://github.com/docs")]])
        #expect(results.first?.kind == .navigation)
        #expect(results.first?.action == .navigate(URL(string: "https://github.com")!))
    }

    @Test func searchSitsBelowPrefixMatchesAndAboveLooseOnes() {
        let results = ranker.rank(
            query: "swift",
            candidatesByProvider: [
                typed("swift"),
                [page("Swift book", "https://a.test/"), page("Quickswift", "https://b.test/")],
            ])
        #expect(results.map(\.kind) == [.history, .search, .history])
    }

    @Test func searchForTypedAddressSitsAtTheBottomBelowLooseMatches() {
        let results = ranker.rank(
            query: "a.com",
            candidatesByProvider: [typed("a.com"), [page("Visit a.com now", "https://z.test/")]])
        #expect(results.map(\.kind) == [.navigation, .history, .search])
    }

    @Test func tabHidesHistoryAndTypedAddressForTheSameURL() {
        let results = ranker.rank(
            query: "example.com",
            candidatesByProvider: [
                typed("example.com"),
                [page("Example", "https://www.example.com/")],
                [tab("Example", "https://example.com")],
            ])
        #expect(results.filter { $0.url.host?.hasSuffix("example.com") == true }.map(\.kind).count == 1)
        #expect(results.first.map { if case .openTab = $0.kind { true } else { false } } == true)
    }

    @Test func historyHidesTheTypedAddressAndKeepsOnlyTheNewestVisit() {
        let results = ranker.rank(
            query: "example.com",
            candidatesByProvider: [
                typed("example.com"),
                [page("Old", "https://example.com/", age: 100), page("New", "http://example.com#top", age: 1)],
            ])
        #expect(results.filter { $0.kind != .search }.map(\.title) == ["New"])
    }

    @Test func equalScoresGoToTheMostRecentlyUsed() {
        let results = ranker.rank(
            query: "news",
            candidatesByProvider: [
                [page("News A", "https://a.test/", age: 500), page("News B", "https://b.test/", age: 10)]
            ])
        #expect(titles(results) == ["News B", "News A"])
    }

    @Test func equalScoresAndRecencyGoToTheProviderRegisteredFirst() {
        let results = ranker.rank(
            query: "news",
            candidatesByProvider: [[page("News Z", "https://z.test/")], [page("News A", "https://a.test/")]])
        #expect(titles(results) == ["News Z", "News A"])
    }

    @Test func emptyQueryListsTabsAndPagesByRecencyWithoutSearch() {
        let results = ranker.rank(
            query: "  ",
            candidatesByProvider: [
                [tab("Old tab", "https://a.test/", age: 900), tab("New tab", "https://b.test/", age: 5)],
                [page("Page", "https://c.test/", age: 1)],
            ])
        #expect(titles(results) == ["New tab", "Old tab", "Page"])
    }

    @Test func resultsAreCapped() {
        let many = (0..<20).map { page("News \($0)", "https://n\($0).test/", age: Double($0)) }
        let results = CommandBarRanker(maxResults: 5).rank(query: "news", candidatesByProvider: [many])
        #expect(results.count == 5)
        #expect(results.first?.title == "News 0")
    }

    @Test func choosingATabSwitchesAndChoosingAnythingElseNavigates() {
        let open = tab("Open", "https://open.test/")
        let results = ranker.rank(
            query: "open", candidatesByProvider: [typed("open"), [open, page("Open page", "https://old.test/")]])
        #expect(results.contains { $0.action == .switchToTab(tabID(open)) })
        #expect(results.filter { $0.kind == .history }.allSatisfy { $0.action == .navigate($0.url) })
    }

    @Test func searchKeepsItsPlaceWhenAnOpenTabHidesTheTypedAddress() {
        let results = ranker.rank(
            query: "example.com",
            candidatesByProvider: [
                typed("example.com"),
                [tab("Example", "https://example.com"), page("Visit example.com", "https://z.test/")],
            ])
        #expect(results.map(\.title) == ["Example", "example.com", "Visit example.com"])
        #expect(results[1].kind == .search)
    }

    @Test func aSchemeInsideTheTextIsNotTreatedAsTheAddress() {
        let results = ranker.rank(
            query: "redirect?u=http://x.com",
            candidatesByProvider: [typed("redirect?u=http://x.com"), [tab("X", "https://x.com/")]])
        #expect(results.map(\.kind) == [.search])
    }

    func tabID(_ candidate: CommandBarCandidate) -> UUID {
        guard case .openTab(let id) = candidate.kind else { fatalError("not a tab") }
        return id
    }
}

/// Commands, the app's own actions, in the command bar.
@Suite struct CommandBarCommandTests {
    let collapse = CommandBarCommand(id: "collapse-all-folders", title: "Collapse All Folders")

    func results(_ query: String, tabs: [CommandBarCandidate] = []) async -> [CommandBarResult] {
        let commands = await CommandsProvider(commands: [collapse]).candidates(for: query)
        return CommandBarRanker().rank(query: query, candidatesByProvider: [tabs, commands])
    }

    @Test func aTypedWordOfTheNameOffersTheCommandThatRunsIt() async {
        let found = await results("collapse")
        #expect(found.first?.action == .runCommand("collapse-all-folders"))
        #expect(found.first?.kind == .command("collapse-all-folders"))
        #expect(found.first?.id == "command:collapse-all-folders")
        #expect(await results("all fol").first?.action == .runCommand("collapse-all-folders"))
    }

    @Test func aBlankBarAndUnrelatedTextOfferNoCommand() async {
        #expect(await results("").isEmpty)
        #expect(await results("zebra").allSatisfy { $0.kind != .command("collapse-all-folders") })
    }

    @Test func aTabWithTheSameMatchSortsBeforeTheCommand() async {
        let tab = CommandBarCandidate(
            kind: .openTab(UUID()), title: "Collapse notes", url: URL(string: "https://a.test/")!)
        let found = await results("collapse", tabs: [tab])
        #expect(found.first?.title == "Collapse notes")
        #expect(found.contains { $0.action == .runCommand("collapse-all-folders") })
    }
}
