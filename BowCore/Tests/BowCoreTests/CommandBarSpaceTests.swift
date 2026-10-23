import BowCoreTestSupport
import Foundation
import Testing

@testable import BowCore

@Suite struct CommandBarSpaceTests {
    let tabA = UUID()
    let tabB = UUID()
    let tabC = UUID()
    let tabFavorite = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func itemID(_ tab: UUID) -> SidebarItemID { SidebarItemID(tab.uuidString.lowercased()) }

    /// Spaces "work" (tabs A and B, A pinned) and "personal" (tab C), with a Favorite of the default
    /// profile. "work" is on screen with B selected.
    private func makeStore(in folder: URL) throws -> SidebarStore {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let first = store.graph.spaces[0]
        try store.renameSpace(first.id, to: "work")
        let personal = try store.createSpace(title: "personal", activate: false)
        let second = try #require(store.graph.space(personal))
        let favorites = try #require(store.graph.favoritesContainerIDs[.default])
        try store.apply([
            .insert(.tab(id: itemID(tabA), url: "https://a.example"), parent: first.pinnedContainerID),
            .insert(.tab(id: itemID(tabB), url: "https://b.example"), parent: first.unpinnedContainerID),
            .insert(.tab(id: itemID(tabC), url: "https://c.example"), parent: second.unpinnedContainerID),
            .insert(.tab(id: itemID(tabFavorite), url: "https://f.example"), parent: favorites),
            .setActiveTab(itemID(tabB)),
        ])
        return store
    }

    private func info(_ id: UUID, _ title: String) -> OpenTabInfo {
        OpenTabInfo(id: id, title: title, url: URL(string: "https://\(title.lowercased()).example/")!, lastActive: now)
    }

    @Test func openTabResultsCarryTheirSpaceNameAndProfile() async throws {
        try await withTemporaryFolderAsync { folder in
            let store = try makeStore(in: folder)
            let work = try #require(store.graph.spaces.first { $0.title == "work" })
            let spaces = OpenTabSpaces(graph: store.graph)
            let source = SpaceAnnotatingOpenTabSource(StubOpenTabSource([info(tabA, "A"), info(tabC, "C")])) { spaces }
            let registry = CommandBarRegistry()
            await registry.register(OpenTabsProvider(source: source))

            let results = await registry.results(for: "")
            let a = try #require(results.first { $0.title == "A" })
            let c = try #require(results.first { $0.title == "C" })
            #expect(a.space == SpaceSummary(id: work.id, name: "work", profileID: .default))
            #expect(c.space?.name == "personal")
            #expect(c.space?.id != work.id)
            #expect(a.action == .switchToTab(tabA))
        }
    }

    @Test func theSpaceFollowsRenamesAndMovesInTheNextSnapshot() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let personal = try #require(store.graph.spaces.first { $0.title == "personal" })
            #expect(OpenTabSpaces(graph: store.graph).space(of: tabA)?.name == "work")
            try store.moveToSpace(itemID(tabA), space: personal.id)
            try store.renameSpace(personal.id, to: "home")
            #expect(OpenTabSpaces(graph: store.graph).space(of: tabA)?.name == "home")
        }
    }

    @Test func aFavoriteAndAnUnlistedTabHaveNoSingleSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let spaces = OpenTabSpaces(graph: store.graph)
            #expect(spaces.space(of: tabFavorite) == nil)
            #expect(spaces.space(of: UUID()) == nil)
            let annotated = spaces.annotated([info(tabFavorite, "F"), info(tabA, "A")])
            #expect(annotated.map { $0.space?.name } == [nil, "work"])
        }
    }

    @Test func aCustomIDMappingIsUsed() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let spaces = OpenTabSpaces(graph: store.graph) { _ in SidebarItemID(self.itemID(self.tabC).rawValue) }
            #expect(spaces.space(of: UUID())?.name == "personal")
        }
    }

    @Test func onlyOpenTabResultsCarryASpace() {
        let summary = SpaceSummary(id: "s", name: "work", profileID: .default)
        let url = URL(string: "https://x.example/")!
        let tab = CommandBarResult(
            candidate: CommandBarCandidate(kind: .openTab(tabA), title: "x", url: url, space: summary))
        let page = CommandBarResult(
            candidate: CommandBarCandidate(kind: .history, title: "x", url: url, space: summary))
        #expect(tab.space == summary)
        #expect(page.space == nil)
    }

    @Test func rankingKeepsEachTabsOwnSpaceWhenTwoTabsShareAnAddress() {
        let work = SpaceSummary(id: "w", name: "work", profileID: "job")
        let home = SpaceSummary(id: "h", name: "home", profileID: .default)
        let url = URL(string: "https://same.example/")!
        let results = CommandBarRanker().rank(
            query: "same",
            candidatesByProvider: [
                [
                    CommandBarCandidate(kind: .openTab(tabA), title: "Same", url: url, lastUsed: now, space: work),
                    CommandBarCandidate(kind: .openTab(tabC), title: "Same", url: url, lastUsed: now - 1, space: home),
                ]
            ])
        #expect(results.map(\.space) == [work, home])
        #expect(results.map(\.action) == [.switchToTab(tabA), .switchToTab(tabC)])
    }

    @Test func choosingATabInAnotherSpaceSwitchesToThatSpaceAndSelectsTheTab() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let personal = try #require(store.graph.spaces.first { $0.title == "personal" })
            let switched = try store.perform(.switchToTab(tabC))
            #expect(switched == personal.id)
            #expect(store.graph.activeSpaceID == personal.id)
            #expect(store.graph.activeTabID == itemID(tabC))
        }
    }

    @Test func choosingATabInTheSameSpaceOnlySelectsIt() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try #require(store.graph.spaces.first { $0.title == "work" })
            #expect(try store.selectOpenTab(tabA) == nil)
            #expect(store.graph.activeSpaceID == work.id)
            #expect(store.graph.activeTabID == itemID(tabA))
        }
    }

    @Test func choosingAFavoriteDoesNotSwitchSpaces() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph.activeSpaceID
            #expect(try store.selectOpenTab(tabFavorite) == nil)
            #expect(store.graph.activeSpaceID == before)
            #expect(store.graph.activeTabID == itemID(tabFavorite))
        }
    }

    @Test func choosingAnUnlistedTabChangesNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(throws: (any Error).self) { try store.selectOpenTab(UUID()) }
            #expect(store.graph == before)
        }
    }

    @Test func otherActionsAreLeftToTheApp() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(try store.perform(.navigate(URL(string: "https://x.example/")!)) == nil)
            #expect(store.graph == before)
        }
    }
}

/// `withTemporaryFolder` for async bodies.
private func withTemporaryFolderAsync(_ body: (URL) async throws -> Void) async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("CommandBarSpaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try await body(folder)
}
