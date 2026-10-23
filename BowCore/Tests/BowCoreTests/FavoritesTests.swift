import Foundation
import Testing

@testable import BowCore

@Suite struct FavoritesTests {
    /// A store with Spaces "work" and "home" on the default profile and "client" on its own profile, no tabs yet.
    private func makeStore(in folder: URL) throws -> SidebarStore {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        try store.renameSpace(store.graph.spaces[0].id, to: "work")
        try store.createSpace(title: "home", activate: false)
        try store.createSpace(title: "client", profileID: "client-profile", activate: false)
        return store
    }

    private func space(_ title: String, in store: SidebarStore) throws -> SidebarSpace {
        try #require(store.graph.spaces.first { $0.title == title })
    }

    private func favorites(_ store: SidebarStore, _ profile: SidebarProfileID = .default) -> [SidebarItemID] {
        store.graph.favoriteIDs(for: profile)
    }

    @Test func aFreshSidebarHasEmptyDefaultFavorites() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            #expect(store.graph.favoritesContainerIDs.keys.sorted() == [.default])
            #expect(favorites(store).isEmpty)
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func addingFavoritesKeepsTheirSavedAddressAndOrder() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let a = try store.addFavorite(url: "https://a.example/?q=x y", title: "A")
            let b = try store.addFavorite(url: "https://b.example", title: "B")
            let first = try store.addFavorite(url: "https://c.example", title: "C", at: 0)
            #expect(favorites(store) == [first, a, b])
            #expect(store.graph[a]?.tab == SidebarTab(savedURL: "https://a.example/?q=x y", savedTitle: "A"))
            #expect(store.graph[a]?.parentID == store.graph.favoritesContainerID(for: .default))
            #expect(store.graph.integrityProblems().isEmpty)
            #expect(throws: SidebarStoreError.invalidIndex(9)) {
                try store.addFavorite(url: "https://d.example", at: 9)
            }
            #expect(favorites(store) == [first, a, b])
        }
    }

    @Test func spacesOfOneProfileShareFavoritesAndAnotherProfileHasItsOwn() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            let home = try space("home", in: store)
            let client = try space("client", in: store)
            let a = try store.addFavorite(url: "https://a.example")
            try store.switchToSpace(home.id)
            #expect(store.graph.activeFavoriteIDs == [a])
            try store.switchToSpace(client.id)
            #expect(store.graph.activeFavoriteIDs.isEmpty)
            let c = try store.addFavorite(url: "https://c.example")
            #expect(favorites(store, "client-profile") == [c])
            #expect(favorites(store) == [a])
            #expect(store.graph.isInFavorites(a, shownBy: work.id))
            #expect(!store.graph.isInFavorites(a, shownBy: client.id))
            #expect(store.graph.favoritesProfileID(containing: c) == "client-profile")
        }
    }

    @Test func aSpaceOnANewProfileGetsItsFavoritesSection() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.favoritesContainerIDs.keys.sorted() == ["client-profile", .default])
            #expect(store.graph.integrityProblems().isEmpty)
            // Deleting the only Space of a profile keeps that profile's Favorites.
            let client = try space("client", in: store)
            let c = try store.addFavorite(url: "https://c.example", profile: "client-profile")
            try store.deleteSpace(client.id)
            #expect(favorites(store, "client-profile") == [c])
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func addingToAProfileWithNoFavoritesIsRefused() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(throws: SidebarStoreError.invalidHierarchy("profile ghost has no favorites")) {
                try store.addFavorite(url: "https://a.example", profile: "ghost")
            }
            #expect(store.graph == before)
        }
    }

    @Test func draggingATabIntoFavoritesMovesItAndReturnsToThePageItWasFavoritedOn() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            try store.apply([
                .insert(.tab(id: "T", url: "https://old.example", title: "Old"), parent: work.unpinnedContainerID),
                .insert(.tab(id: "U", url: "https://u.example"), parent: work.unpinnedContainerID),
                .setActiveTab("T"),
            ])
            try store.moveToFavorites("T", page: (url: "https://new.example/page", title: "New"))
            #expect(favorites(store) == ["T"])
            #expect(store.graph.tabIDs(in: work.id) == ["U"])
            #expect(store.graph["T"]?.tab == SidebarTab(savedURL: "https://new.example/page", savedTitle: "New"))
            #expect(store.graph.activeTabID == "T")
            #expect(store.graph.isInFavorites("T"))
            #expect(!store.graph.isInFavorites("U"))

            // Without a page the tab keeps the address it was saved with.
            try store.moveToFavorites("U", at: 0)
            #expect(favorites(store) == ["U", "T"])
            #expect(store.graph["U"]?.tab?.savedURL == "https://u.example")
        }
    }

    @Test func favoritesHoldOnlyTabs() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            try store.apply([
                .insert(.folder(id: "F", title: "Folder"), parent: work.pinnedContainerID),
                .insert(.split(id: "S"), parent: work.pinnedContainerID),
                .insert(.tab(id: "in-split", url: "https://s.example"), parent: "S"),
            ])
            let before = store.graph
            #expect(throws: SidebarStoreError.self) { try store.moveToFavorites("F") }
            #expect(throws: SidebarStoreError.self) { try store.moveToFavorites("S") }
            #expect(store.graph == before)
            let container = try #require(store.graph.favoritesContainerID(for: .default))
            #expect(throws: SidebarStoreError.self) {
                try store.apply([.insert(.folder(id: "G", title: "G"), parent: container)])
            }
            #expect(store.graph == before)
        }
    }

    @Test func reorderingMovesAFavoriteToItsFinalPosition() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let a = try store.addFavorite(url: "https://a.example")
            let b = try store.addFavorite(url: "https://b.example")
            let c = try store.addFavorite(url: "https://c.example")
            try store.reorderFavorite(a, to: 2)
            #expect(favorites(store) == [b, c, a])
            try store.reorderFavorite(a, to: 0)
            #expect(favorites(store) == [a, b, c])
            try store.reorderFavorite(b, to: 1)
            #expect(favorites(store) == [a, b, c])
            #expect(throws: SidebarStoreError.invalidIndex(3)) { try store.reorderFavorite(a, to: 3) }
            #expect(favorites(store) == [a, b, c])
        }
    }

    @Test func reorderingSomethingThatIsNotAFavoriteIsRefused() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            try store.apply([.insert(.tab(id: "T", url: "https://t.example"), parent: work.unpinnedContainerID)])
            let before = store.graph
            #expect(throws: SidebarStoreError.invalidHierarchy("T is not a favorite")) {
                try store.reorderFavorite("T", to: 0)
            }
            #expect(throws: SidebarStoreError.invalidHierarchy("T is not a favorite")) { try store.removeFavorite("T") }
            #expect(throws: SidebarStoreError.invalidHierarchy("T is not a favorite")) { try store.deleteFavorite("T") }
            #expect(store.graph == before)
        }
    }

    @Test func removingAFavoriteKeepsItAsATabInTheSpaceOnScreen() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            let a = try store.addFavorite(url: "https://a.example", title: "A")
            let b = try store.addFavorite(url: "https://b.example", title: "B")
            try store.apply([.insert(.tab(id: "T", url: "https://t.example"), parent: work.unpinnedContainerID)])
            try store.removeFavorite(a)
            #expect(favorites(store) == [b])
            #expect(store.graph.tabIDs(in: work.id) == [a, "T"])
            #expect(store.graph[a]?.tab == SidebarTab(savedURL: "https://a.example", savedTitle: "A"))
            try store.removeFavorite(b, to: .pinned)
            #expect(favorites(store).isEmpty)
            #expect(store.graph.children(of: work.pinnedContainerID).map(\.id) == [b])
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func removingASelectedFavoriteIntoAnotherSpaceSelectsTheOnScreenSpacesOwnTab() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            let home = try space("home", in: store)
            try store.apply([.insert(.tab(id: "T", url: "https://t.example"), parent: work.unpinnedContainerID)])
            let a = try store.addFavorite(url: "https://a.example")
            try store.selectTab(a)
            try store.removeFavorite(a, in: home.id)
            #expect(store.graph.activeSpaceID == work.id)
            #expect(store.graph.activeTabID == "T")
            #expect(store.graph.tabIDs(in: home.id) == [a])
        }
    }

    @Test func deletingAFavoriteRemovesItForGood() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let a = try store.addFavorite(url: "https://a.example")
            let b = try store.addFavorite(url: "https://b.example")
            try store.deleteFavorite(a)
            #expect(favorites(store) == [b])
            #expect(store.graph[a] == nil)
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func aFavoriteStaysSelectedAcrossSpacesOfItsProfileButNotAcrossProfiles() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            let home = try space("home", in: store)
            let client = try space("client", in: store)
            try store.apply([.insert(.tab(id: "C1", url: "https://c1.example"), parent: client.unpinnedContainerID)])
            let a = try store.addFavorite(url: "https://a.example")
            try store.selectTab(a)
            try store.switchToSpace(home.id)
            #expect(store.graph.activeTabID == a)
            try store.switchToSpace(client.id)
            #expect(store.graph.activeTabID == "C1")
            // Selecting it again brings a Space of its profile on screen.
            try store.selectTab(a)
            #expect(store.graph.activeSpaceID == work.id)
            #expect(store.graph.activeTabID == a)
        }
    }

    @Test func selectingAFavoriteNoSpaceShowsIsRefused() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let client = try space("client", in: store)
            let c = try store.addFavorite(url: "https://c.example", profile: "client-profile")
            try store.deleteSpace(client.id)
            let before = store.graph
            #expect(throws: SidebarStoreError.self) { try store.selectTab(c) }
            #expect(store.graph == before)
        }
    }

    @Test func archivingAndOtherCleanupCanAskWhetherAnItemIsInFavorites() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try space("work", in: store)
            let a = try store.addFavorite(url: "https://a.example")
            let c = try store.addFavorite(url: "https://c.example", profile: "client-profile")
            try store.apply([.insert(.tab(id: "T", url: "https://t.example"), parent: work.pinnedContainerID)])
            #expect(store.graph.isInFavorites(a))
            #expect(store.graph.isInFavorites(c))
            #expect(!store.graph.isInFavorites("T"))
            #expect(!store.graph.isInFavorites("missing"))
        }
    }

    @Test func favoritesSurviveARelaunchInOrderPerProfile() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("Sidebar.json")
            let store = try makeStore(in: folder)
            let a = try store.addFavorite(url: "https://a.example", title: "A")
            let b = try store.addFavorite(url: "https://b.example", title: "B")
            let c = try store.addFavorite(url: "https://c.example", profile: "client-profile")
            try store.reorderFavorite(a, to: 1)
            let reopened = try SidebarStore(fileURL: url)
            #expect(reopened.graph == store.graph)
            #expect(reopened.openReport.repairs.isEmpty)
            #expect(reopened.graph.favoriteIDs(for: .default) == [b, a])
            #expect(reopened.graph.favoriteIDs(for: "client-profile") == [c])
            #expect(reopened.graph[a]?.tab == SidebarTab(savedURL: "https://a.example", savedTitle: "A"))
        }
    }

    // MARK: Repair

    @Test func repairRecreatesAMissingFavoritesSectionForTheDefaultAndForEachSpaceProfile() {
        var graph = SidebarGraph.sample()
        graph.spaces[0].profileID = "other"
        graph.favoritesContainerIDs = [:]
        graph.items["favorites"] = nil
        let log = graph.repair()
        #expect(Set(graph.favoritesContainerIDs.keys) == [.default, "other"])
        #expect(log.filter { if case .createdContainer(_, .favorites) = $0 { true } else { false } }.count == 2)
        #expect(graph.integrityProblems().isEmpty)
    }

    @Test func repairKeepsFavoritesOfAProfileNoSpaceUsesAndMovesStrayItemsOutOfFavorites() throws {
        var graph = try SidebarGraph.sample().applying([
            .insert(.tab(id: "kept", url: "https://k.example"), parent: "favorites")
        ])
        let spare = SidebarItem(id: "spare-favorites", data: .container(SidebarContainer(kind: .favorites)))
        graph.items[spare.id] = spare
        graph.favoritesContainerIDs["spare"] = spare.id
        // A folder somehow listed under Favorites cannot stay there.
        graph.items["stray"] = SidebarItem(id: "stray", parentID: "favorites", data: .folder(SidebarFolder()))
        graph.items["favorites"]?.childrenIDs.append("stray")
        let log = graph.repair()
        #expect(graph.favoritesContainerIDs["spare"] == "spare-favorites")
        #expect(graph["spare-favorites"] != nil)
        #expect(graph.favoriteIDs(for: .default) == ["kept"])
        #expect(graph[.recentlyRecovered]?.childrenIDs == ["stray"])
        #expect(log.contains(.recovered("stray")))
        #expect(graph.integrityProblems().isEmpty)
    }

    @Test func repairGivesASharedSectionToOnlyOneProfile() {
        var graph = SidebarGraph.sample()
        graph.favoritesContainerIDs["twin"] = "favorites"
        graph.repair()
        let ids = graph.favoritesContainerIDs.values
        #expect(Set(ids).count == ids.count)
        #expect(graph.favoritesContainerIDs[.default] == "favorites")
        #expect(graph.integrityProblems().isEmpty)
    }
}
