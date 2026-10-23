import Foundation
import Testing

@testable import BowCore

@Suite struct PinnedTabsTests {
    private let pageA = URL(string: "https://a.example.com/home")!
    private let pageB = URL(string: "https://b.example.com/other")!

    /// A store with Space "work" (on screen): pinned mail and docs, unpinned news, a folder holding wiki, a split of
    /// left and right, a Favorites tab; and Space "play" with its own pinned game.
    private func makeStore(in folder: URL) throws -> SidebarStore {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let work = store.graph.spaces[0]
        try store.renameSpace(work.id, to: "work")
        let play = try store.createSpace(title: "play", activate: false)
        let playSpace = try #require(store.graph.space(play))
        try store.apply([
            .insert(.tab(id: "mail", url: "https://mail.example.com", title: "Mail"), parent: work.pinnedContainerID),
            .insert(.tab(id: "docs", url: "https://docs.example.com", title: "Docs"), parent: work.pinnedContainerID),
            .insert(.tab(id: "news", url: "https://news.example.com", title: "News"), parent: work.unpinnedContainerID),
            .insert(.folder(id: "folder", title: "Folder"), parent: work.unpinnedContainerID),
            .insert(.tab(id: "wiki", url: "https://wiki.example.com", title: "Wiki"), parent: "folder"),
            .insert(.split(id: "split"), parent: work.unpinnedContainerID),
            .insert(.tab(id: "left", url: "https://left.example.com"), parent: "split"),
            .insert(.tab(id: "right", url: "https://right.example.com"), parent: "split"),
            .insert(
                .tab(id: "fav", url: "https://fav.example.com", title: "Fav"), parent: store.graph.favoritesContainerID),
            .insert(
                .tab(id: "game", url: "https://game.example.com", title: "Game"), parent: playSpace.pinnedContainerID),
            .setActiveTab("news"),
        ])
        return store
    }

    private func pinnedOrder(_ store: SidebarStore) -> [SidebarItemID] {
        store.graph.children(of: store.graph.spaces[0].pinnedContainerID).map(\.id)
    }

    // MARK: pin

    @Test func pinMovesTheTabToTheEndOfThePinnedSectionAndRecordsItsPage() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(try store.pinTab("news", page: (pageA, "Page A")))
            #expect(pinnedOrder(store) == ["mail", "docs", "news"])
            #expect(store.graph.isPinned("news"))
            #expect(store.graph["news"]?.tab == SidebarTab(savedURL: pageA.absoluteString, savedTitle: "Page A"))
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func pinWithoutAPageKeepsWhatTheTabWasSavedWith() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("news", at: 0)
            #expect(pinnedOrder(store) == ["news", "mail", "docs"])
            #expect(store.graph["news"]?.tab == SidebarTab(savedURL: "https://news.example.com", savedTitle: "News"))
        }
    }

    @Test func pinTakesATabOutOfAFolderAloneAndLeavesTheFolderInPlace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("wiki")
            #expect(pinnedOrder(store).last == "wiki")
            #expect(store.graph.children(of: "folder").isEmpty)
        }
    }

    @Test func pinningAFavoritesTabPinsItInTheActiveSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("fav")
            #expect(pinnedOrder(store).last == "fav")
            #expect(!store.graph.isInFavorites("fav"))
        }
    }

    @Test func pinningAnAlreadyPinnedTabChangesNothingNotEvenItsSavedPage() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(try store.pinTab("mail", page: (pageB, "Page B")) == false)
            #expect(store.graph == before)
        }
    }

    @Test func aTabInASplitOrAnItemThatIsNotATabCannotBePinned() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(throws: SidebarStoreError.self) { try store.pinTab("left") }
            #expect(throws: SidebarStoreError.self) { try store.pinTab("folder") }
            #expect(throws: SidebarStoreError.itemNotFound("nope")) { try store.pinTab("nope") }
            #expect(store.graph == before)
        }
    }

    @Test func pinnedTabsBelongToTheirOwnSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = store.graph.spaces[0].id
            let play = store.graph.spaces[1].id
            try store.pinTab("news")
            #expect(store.graph.pinnedTabIDs(in: work) == ["mail", "docs", "news"])
            #expect(store.graph.pinnedTabIDs(in: play) == ["game"])
        }
    }

    @Test func pinningTheSelectedTabKeepsItSelected() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("news")
            #expect(store.graph.activeTabID == "news")
        }
    }

    // MARK: unpin

    @Test func unpinMovesTheTabToTheTopOfTheTabsSection() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(try store.unpinTab("docs"))
            #expect(!store.graph.isPinned("docs"))
            #expect(pinnedOrder(store) == ["mail"])
            #expect(store.graph.children(of: store.graph.unpinnedID).first?.id == "docs")
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func unpinRecordsTheCurrentPageOnlyWhenGivenOne() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.unpinTab("mail", page: (pageB, "Page B"))
            #expect(store.graph["mail"]?.tab == SidebarTab(savedURL: pageB.absoluteString, savedTitle: "Page B"))
            try store.unpinTab("docs")
            #expect(store.graph["docs"]?.tab == SidebarTab(savedURL: "https://docs.example.com", savedTitle: "Docs"))
        }
    }

    @Test func unpinningATabThatIsNotPinnedChangesNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(try store.unpinTab("news") == false)
            #expect(try store.unpinTab("fav") == false)
            #expect(store.graph == before)
        }
    }

    // MARK: reorder

    @Test func reorderMovesAPinnedTabWithinItsSection() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.reorderPinnedTab("docs", to: 0)
            #expect(pinnedOrder(store) == ["docs", "mail"])
            try store.reorderPinnedTab("docs", to: 1)
            #expect(pinnedOrder(store) == ["mail", "docs"])
        }
    }

    @Test func reorderRefusesAnIndexOutOfRangeAndTabsThatAreNotPinned() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(throws: SidebarStoreError.invalidIndex(5)) { try store.reorderPinnedTab("mail", to: 5) }
            #expect(throws: SidebarStoreError.self) { try store.reorderPinnedTab("news", to: 0) }
            #expect(store.graph == before)
        }
    }

    // MARK: close

    @Test func closingAPinnedTabUnloadsItAndKeepsItWhileOtherTabsLeave() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.closeOutcome(for: "mail") == .unloadKeepingInSidebar)
            #expect(store.graph.closeOutcome(for: "news") == .removeFromSidebar)
            #expect(store.graph.closeOutcome(for: "wiki") == .removeFromSidebar)
            try store.pinTab("wiki")
            #expect(store.graph.closeOutcome(for: "wiki") == .unloadKeepingInSidebar)
        }
    }

    @Test func aClosedPinnedTabReopensOnItsSavedAddressNotWhereItWas() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("news", page: (pageA, "Page A"))
            // The page navigated to B, then the tab closed: nothing in the sidebar recorded B.
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageB))
            #expect(store.graph.closeOutcome(for: "news") == .unloadKeepingInSidebar)
            #expect(store.graph.pinnedURL(of: "news") == pageA)
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("news", liveURL: nil) == false)
        }
    }

    // MARK: navigated away

    @Test func aPinnedTabHasNavigatedAwayWhenTheLivePageIsADifferentPage() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("news", page: (pageA, "Page A"))
            let graph = store.graph
            #expect(graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageA) == false)
            #expect(graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageB))
            #expect(graph.hasNavigatedAwayFromPinnedURL("news", liveURL: URL(string: "https://a.example.com/home?x=1")))
            #expect(graph.hasNavigatedAwayFromPinnedURL("news", liveURL: URL(string: "https://a.example.com/other")))
            #expect(graph.hasNavigatedAwayFromPinnedURL("news", liveURL: URL(string: "http://a.example.com/home")))
        }
    }

    @Test func navigatedAwayIgnoresFragmentsCaseDefaultPortsAndAnEmptyPath() {
        let tab = SidebarTab(savedURL: "https://Example.com")
        for same in [
            "https://example.com/", "https://EXAMPLE.com", "https://example.com:443/", "https://example.com/#top",
            "https://example.com#a",
        ] {
            #expect(tab.hasNavigatedAway(from: URL(string: same)) == false, "\(same)")
        }
        #expect(tab.hasNavigatedAway(from: URL(string: "https://example.com:8443/")))
        #expect(tab.hasNavigatedAway(from: URL(string: "https://example.com/x")))
    }

    @Test func navigatedAwayIgnoresEscapeCaseAndAnEmptyQuery() {
        let tab = SidebarTab(savedURL: "https://a.example.com/p%2fq?")
        #expect(tab.hasNavigatedAway(from: URL(string: "https://a.example.com/p%2Fq")) == false)
        #expect(tab.hasNavigatedAway(from: URL(string: "https://a.example.com/p%2Fr")))
    }

    @Test func aSavedAddressThatIsNotAURLHasNothingToGoBackTo() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.apply([.setSavedPage("mail", url: "http://[not-an-address", title: "")])
            #expect(store.graph.pinnedURL(of: "mail") == nil)
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("mail", liveURL: pageB) == false)
        }
    }

    @Test func navigatedAwayIsFalseWithoutALivePageOrASavedAddress() {
        #expect(SidebarTab(savedURL: "https://a.example.com").hasNavigatedAway(from: nil) == false)
        #expect(SidebarTab(savedURL: "").hasNavigatedAway(from: pageB) == false)
        #expect(SidebarTab(savedURL: "  ").savedPageURL == nil)
    }

    @Test func navigatedAwayIsOnlyAskedOfPinnedTabs() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageB) == false)
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("mail", liveURL: pageB))
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("folder", liveURL: pageB) == false)
        }
    }

    // MARK: back to pinned

    @Test func backToPinnedGivesTheSavedAddressAndChangesNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("news", page: (pageA, "Page A"))
            let before = store.graph
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageB))
            #expect(store.graph.pinnedURL(of: "news") == pageA)
            // After the app loads it, the live page is A again.
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageA) == false)
            #expect(store.graph == before)
        }
    }

    @Test func backToPinnedHasNoAddressForATabThatIsNotPinnedOrWasNeverSaved() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.pinnedURL(of: "news") == nil)
            #expect(store.graph.pinnedURL(of: "nope") == nil)
            try store.apply([.setSavedPage("mail", url: "", title: "")])
            #expect(store.graph.pinnedURL(of: "mail") == nil)
        }
    }

    // MARK: replace

    @Test func replaceMakesTheCurrentPageTheSavedOneOnlyWhenAsked() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("news", page: (pageA, "Page A"))
            // Browsing, closing and reopening never change the saved page.
            _ = store.graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageB)
            _ = store.graph.pinnedURL(of: "news")
            #expect(store.graph["news"]?.tab?.savedURL == pageA.absoluteString)

            try store.replacePinnedURL("news", with: (pageB, "Page B"))
            #expect(store.graph["news"]?.tab == SidebarTab(savedURL: pageB.absoluteString, savedTitle: "Page B"))
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("news", liveURL: pageB) == false)
            #expect(store.graph.pinnedURL(of: "news") == pageB)
            #expect(pinnedOrder(store) == ["mail", "docs", "news"])
        }
    }

    @Test func replaceRefusesTabsThatAreNotPinned() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(throws: SidebarStoreError.self) { try store.replacePinnedURL("news", with: (pageB, "B")) }
            #expect(throws: SidebarStoreError.itemNotFound("nope")) {
                try store.replacePinnedURL("nope", with: (pageB, "B"))
            }
            #expect(store.graph == before)
        }
    }

    // MARK: saving

    @Test func pinnedStateSurvivesRelaunchWithTheSavedAddressNotTheLiveOne() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.pinTab("news", page: (pageA, "Page A"))
            try store.reorderPinnedTab("news", to: 0)
            let reopened = try SidebarStore(fileURL: store.fileURL)
            #expect(reopened.openReport.repairs.isEmpty)
            #expect(reopened.graph.children(of: reopened.graph.pinnedID).map(\.id) == ["news", "mail", "docs"])
            #expect(reopened.graph.isPinned("news"))
            #expect(reopened.graph.pinnedURL(of: "news") == pageA)
        }
    }
}
