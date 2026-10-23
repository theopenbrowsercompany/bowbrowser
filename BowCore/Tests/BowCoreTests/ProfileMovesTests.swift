import Foundation
import Testing

@testable import BowCore

@Suite struct ProfileMovesTests {
    private let work = SidebarProfileID("work")
    private let personal = SidebarProfileID("personal")

    /// Spaces "Work A" and "Work B" on profile work (on screen: Work A) and "Home" on personal. Work A holds a pinned
    /// tab P and today tabs A1 and A2 (A1 selected), Work B a today tab B1, Home a today tab H1; work's Favorites
    /// hold F and personal's G.
    private struct Fixture {
        let store: SidebarStore
        let workA: SidebarSpaceID
        let workB: SidebarSpaceID
        let home: SidebarSpaceID
        let pinned = SidebarItem.tab(url: "https://p.test/", title: "P")
        let a1 = SidebarItem.tab(url: "https://a1.test/", title: "A1")
        let a2 = SidebarItem.tab(url: "https://a2.test/", title: "A2")
        let b1 = SidebarItem.tab(url: "https://b1.test/", title: "B1")
        let h1 = SidebarItem.tab(url: "https://h1.test/", title: "H1")
        let favorite: SidebarItemID
        let homeFavorite: SidebarItemID
    }

    private func makeFixture(in folder: URL) throws -> Fixture {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let workA = store.graph.spaces[0].id
        try store.renameSpace(workA, to: "Work A")
        try store.setSpaceProfile(workA, to: work)
        let workB = try store.createSpace(title: "Work B", profileID: work, activate: false)
        let home = try store.createSpace(title: "Home", profileID: personal, activate: false)
        let favorite = try store.addFavorite(url: "https://f.test/", title: "F", profile: work)
        let homeFavorite = try store.addFavorite(url: "https://g.test/", title: "G", profile: personal)
        let fixture = Fixture(
            store: store, workA: workA, workB: workB, home: home, favorite: favorite, homeFavorite: homeFavorite)
        let graph = store.graph
        try store.apply([
            .insert(fixture.pinned, parent: graph.space(workA)!.pinnedContainerID),
            .insert(fixture.a1, parent: graph.space(workA)!.unpinnedContainerID),
            .insert(fixture.a2, parent: graph.space(workA)!.unpinnedContainerID),
            .insert(fixture.b1, parent: graph.space(workB)!.unpinnedContainerID),
            .insert(fixture.h1, parent: graph.space(home)!.unpinnedContainerID),
            .setActiveTab(fixture.a1.id),
        ])
        return fixture
    }

    // MARK: Move to Space

    @Test func aMoveKeepsTheLivePageOnlyBetweenSpacesOfOneProfile() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            let graph = f.store.graph
            #expect(graph.tabMoveKind(of: f.a1.id, to: f.workB) == .keepsLivePage)
            #expect(graph.tabMoveKind(of: f.a1.id, to: f.home) == .needsReload(from: work, to: personal))
            #expect(graph.tabMoveKind(of: f.h1.id, to: f.workA) == .needsReload(from: personal, to: work))
        }
    }

    @Test func aDropOnASpaceIconTakesWhatMoveToSpaceOffers() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            let box = SidebarItem.folder(title: "Box")
            try f.store.apply([.insert(box, parent: f.store.graph.space(f.workA)!.unpinnedContainerID)])
            let graph = f.store.graph
            // A today tab, a pinned tab and the selected tab go to another Space, of either profile.
            #expect(graph.acceptsDrop(of: f.a2.id, onSpace: f.workB))
            #expect(graph.acceptsDrop(of: f.pinned.id, onSpace: f.home))
            #expect(graph.acceptsDrop(of: f.a1.id, onSpace: f.home))
            // Its own Space (the one on screen), an unknown Space, a folder and a Favorite are refused.
            #expect(!graph.acceptsDrop(of: f.a2.id, onSpace: f.workA))
            #expect(!graph.acceptsDrop(of: f.a2.id, onSpace: "nowhere"))
            #expect(!graph.acceptsDrop(of: box.id, onSpace: f.workB))
            #expect(!graph.acceptsDrop(of: f.favorite, onSpace: f.workB))
            #expect(!graph.acceptsDrop(of: "missing", onSpace: f.workB))
        }
    }

    @Test func profileIDsMatchIgnoringCaseForAMove() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            let shouting = try f.store.createSpace(title: "Work C", profileID: "WORK", activate: false)
            // The same profile spelled in another case: no reload.
            #expect(f.store.graph.tabMoveKind(of: f.a1.id, to: shouting) == .keepsLivePage)
        }
    }

    @Test func moveTargetsAreTheOtherSpacesAndOnlyForTabsOfASpace() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            let graph = f.store.graph
            #expect(graph.spaceMoveTargets(for: f.a1.id).map(\.id) == [f.workB, f.home])
            #expect(graph.spaceMoveTargets(for: f.h1.id).map(\.id) == [f.workA, f.workB])
            #expect(graph.spaceMoveTargets(for: f.favorite).isEmpty)
            #expect(graph.spaceMoveTargets(for: graph.space(f.workA)!.pinnedContainerID).isEmpty)
            #expect(graph.spaceMoveTargets(for: "missing").isEmpty)
            #expect(graph.tabMoveKind(of: f.a1.id, to: f.workA) == nil)
            #expect(graph.tabMoveKind(of: f.favorite, to: f.workB) == nil)
            #expect(graph.tabMoveKind(of: f.a1.id, to: "nowhere") == nil)
        }
    }

    @Test func aFolderOrSplitTabCanMoveButAFolderIsNoTarget() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            let box = SidebarItem.folder(title: "Box")
            let inside = SidebarItem.tab(url: "https://in.test/", title: "In")
            try f.store.apply([
                .insert(box, parent: f.store.graph.space(f.workA)!.unpinnedContainerID),
                .insert(inside, parent: box.id),
            ])
            #expect(f.store.graph.spaceMoveTargets(for: box.id).isEmpty)
            #expect(f.store.graph.tabMoveKind(of: inside.id, to: f.home) == .needsReload(from: work, to: personal))
            try f.store.moveTab(inside.id, toSpace: f.workB)
            #expect(f.store.graph.spaceID(containing: inside.id) == f.workB)
            #expect(f.store.graph[box.id]?.childrenIDs == [])
        }
    }

    @Test func moveTabKeepsItsSectionAtTheTopAndTheSpaceOnScreen() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            try f.store.moveTab(f.a1.id, toSpace: f.workB)
            try f.store.moveTab(f.pinned.id, toSpace: f.workB)
            let graph = f.store.graph
            let workB = try #require(graph.space(f.workB))
            #expect(graph.children(of: workB.unpinnedContainerID).map(\.id) == [f.a1.id, f.b1.id])
            #expect(graph.children(of: workB.pinnedContainerID).map(\.id) == [f.pinned.id])
            #expect(graph.activeSpaceID == f.workA)
            // The selected tab left the Space on screen, which selects its own tab.
            #expect(graph.activeTabID == f.a2.id)
        }
    }

    @Test func moveTabRefusesWhatMoveToSpaceDoesNotOffer() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            #expect(throws: SidebarStoreError.spaceNotFound("nowhere")) {
                try f.store.moveTab(f.a1.id, toSpace: "nowhere")
            }
            #expect(throws: SidebarStoreError.self) { try f.store.moveTab(f.a1.id, toSpace: f.workA) }
            #expect(throws: SidebarStoreError.self) { try f.store.moveTab(f.favorite, toSpace: f.workB) }
            #expect(f.store.graph.spaceID(containing: f.a1.id) == f.workA)
            #expect(f.store.graph.isInFavorites(f.favorite))
        }
    }

    // MARK: Favorites

    @Test func favoritesRefuseATabOfAnotherProfilesSpace() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            #expect(throws: SidebarStoreError.crossProfileMove(f.h1.id)) {
                try f.store.moveToFavorites(f.h1.id, profile: work)
            }
            // With no profile given, the Favorites of the Space on screen (Work A, on work) are meant.
            #expect(throws: SidebarStoreError.crossProfileMove(f.h1.id)) { try f.store.moveToFavorites(f.h1.id) }
            #expect(f.store.graph.spaceID(containing: f.h1.id) == f.home)
            #expect(f.store.graph.favoriteIDs(for: work) == [f.favorite])
            // A tab of a Space on the same profile, even another Space, goes in.
            try f.store.moveToFavorites(f.b1.id, profile: work)
            #expect(f.store.graph.favoriteIDs(for: work) == [f.favorite, f.b1.id])
        }
    }

    @Test func favoritesRefuseAnotherProfilesFavorite() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            #expect(throws: SidebarStoreError.crossProfileMove(f.homeFavorite)) {
                try f.store.moveToFavorites(f.homeFavorite, profile: work)
            }
            #expect(f.store.graph.favoriteIDs(for: personal) == [f.homeFavorite])
            // Reordering within its own Favorites still works.
            try f.store.moveToFavorites(f.homeFavorite, profile: personal, at: 0)
            #expect(f.store.graph.favoriteIDs(for: personal) == [f.homeFavorite])
        }
    }

    @Test func removeFavoriteRefusesASpaceOfAnotherProfile() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            #expect(throws: SidebarStoreError.crossProfileMove(f.favorite)) {
                try f.store.removeFavorite(f.favorite, in: f.home)
            }
            #expect(f.store.graph.favoriteIDs(for: work) == [f.favorite])
            // Into a Space of its own profile, on screen or not, it goes.
            try f.store.removeFavorite(f.favorite, in: f.workB)
            #expect(f.store.graph.spaceID(containing: f.favorite) == f.workB)
        }
    }

    @Test func removeFavoriteMatchesProfilesIgnoringCase() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            let shouting = try f.store.createSpace(title: "Work C", profileID: "WORK", activate: false)
            try f.store.removeFavorite(f.favorite, in: shouting)
            #expect(f.store.graph.spaceID(containing: f.favorite) == shouting)
        }
    }

    @Test func crossesProfilesReadsTheHoldingSpaceOrFavorites() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            let graph = f.store.graph
            #expect(graph.profileID(holding: f.a1.id) == work)
            #expect(graph.profileID(holding: f.homeFavorite) == personal)
            #expect(graph.profileID(holding: "missing") == nil)
            #expect(!graph.crossesProfiles(f.a1.id, intoFavoritesOf: "WORK"))
            #expect(graph.crossesProfiles(f.a1.id, intoFavoritesOf: personal))
            #expect(!graph.crossesProfiles("missing", intoFavoritesOf: personal))
        }
    }

    // MARK: A selected Favorite across Spaces

    @Test func aSelectedFavoriteIsRememberedWhenSwitchingToAnotherProfilesSpace() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            try f.store.apply([.setActiveTab(f.favorite)])
            try f.store.switchToSpace(f.home)
            #expect(f.store.graph.activeTabID == f.h1.id)
            try f.store.switchToSpace(f.workA)
            #expect(f.store.graph.activeTabID == f.favorite)
        }
    }

    @Test func aSelectedFavoriteStaysSelectedInASpaceOfTheSameProfile() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            try f.store.apply([.setActiveTab(f.favorite)])
            try f.store.switchToSpace(f.workB)
            #expect(f.store.graph.activeTabID == f.favorite)
        }
    }

    @Test func aRememberedFavoriteTheSpaceNoLongerShowsGivesWay() throws {
        try withTemporaryFolder { folder in
            let f = try makeFixture(in: folder)
            try f.store.apply([.setActiveTab(f.favorite)])
            try f.store.switchToSpace(f.home)
            // Work A moves to personal, whose Favorites do not hold F.
            try f.store.setSpaceProfile(f.workA, to: personal)
            try f.store.switchToSpace(f.workA)
            #expect(f.store.graph.activeTabID == f.pinned.id)
        }
    }

    // MARK: Deleting profiles

    @Test func onlyProfilesNoSpaceShowsCanBeDeletedAndNeverTheDefault() throws {
        try withTemporaryFolder { folder in
            let registry = try ProfileRegistry(
                fileURL: folder.appendingPathComponent(ProfileRegistry.fileName),
                dataRoot: folder.appendingPathComponent("Chromium", isDirectory: true))
            let job = try registry.create(name: "Work")
            let home = try registry.create(name: "Home")
            let temp = try registry.create(name: "Temp", isPersistent: false)
            let deletable = registry.deletableProfiles(spaceProfiles: [.default, SidebarProfileID("WORK")])
            #expect(deletable.map(\.id) == [home.id, temp.id])
            #expect(registry.deletableProfiles(spaceProfiles: []).map(\.id) == [job.id, home.id, temp.id])
            #expect(!registry.deletableProfiles(spaceProfiles: []).contains { $0.isDefault })
        }
    }
}
