import Foundation
import Testing

@testable import BowCore

@Suite struct SpaceProfilesTests {
    private let work = SidebarProfileID("work")
    private let personal = SidebarProfileID("personal")

    @Test func pointingASpaceAtAnotherProfileReturnsItsTabsAndSaves() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("Sidebar.json")
            let store = try SidebarStore(fileURL: url)
            let space = store.graph.spaces[0]
            let pinned = SidebarItem.tab(url: "https://a.test/", title: "A")
            let today = SidebarItem.tab(url: "https://b.test/", title: "B")
            try store.apply([
                .insert(pinned, parent: space.pinnedContainerID), .insert(today, parent: space.unpinnedContainerID),
            ])
            let tabs = try store.setSpaceProfile(space.id, to: work)
            #expect(tabs == [pinned.id, today.id])
            #expect(store.graph.space(space.id)?.profileID == work)
            // The new profile gets its own Favorites, and the default keeps its.
            #expect(store.graph.favoritesContainerID(for: work) != nil)
            #expect(store.graph.favoritesContainerID(for: .default) != nil)
            let reopened = try SidebarStore(fileURL: url)
            #expect(reopened.graph.space(space.id)?.profileID == work)
        }
    }

    @Test func theSameProfileIgnoringCaseChangesNothing() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let space = try store.createSpace(title: "Work", profileID: work)
            let tab = SidebarItem.tab(url: "https://a.test/", title: "A")
            try store.apply([.insert(tab, parent: store.graph.space(space)!.unpinnedContainerID)])
            #expect(store.graph.spaceProfileChange(space, to: SidebarProfileID("WORK")) == .unchanged)
            #expect(try store.setSpaceProfile(space, to: SidebarProfileID("WORK")) == [])
            #expect(store.graph.space(space)?.profileID == work)
        }
    }

    @Test func spacesSharingAProfileShareItsFavoritesAndTheOldOnesKeepTheirs() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let first = store.graph.spaces[0].id
            let second = try store.createSpace(title: "Two", profileID: personal, activate: false)
            try store.setSpaceProfile(first, to: work)
            let workFavorites = store.graph.favoritesContainerID(for: work)
            try store.setSpaceProfile(second, to: work)
            #expect(store.graph.favoritesContainerID(for: work) == workFavorites)
            #expect(store.graph.favoritesContainerID(for: personal) != nil)
        }
    }

    @Test func aSelectedFavoriteOfTheOldProfileGivesWayToTheSpacesOwnTab() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let space = store.graph.spaces[0]
            let own = SidebarItem.tab(url: "https://a.test/", title: "A")
            try store.apply([.insert(own, parent: space.unpinnedContainerID)])
            let favorite = try store.addFavorite(url: "https://f.test/", title: "F")
            try store.apply([.setActiveTab(favorite)])
            try store.setSpaceProfile(space.id, to: work)
            #expect(store.graph.activeTabID == own.id)
            // The Favorite stays with its profile.
            #expect(store.graph.favoriteIDs(for: .default) == [favorite])
            #expect(store.graph.favoriteIDs(for: work) == [])
        }
    }

    @Test func anUnknownSpaceIsRefused() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            #expect(store.graph.spaceProfileChange("missing", to: work) == nil)
            #expect(throws: SidebarStoreError.spaceNotFound("missing")) {
                try store.setSpaceProfile("missing", to: work)
            }
        }
    }

    @Test func choicesListEveryProfileWithTheCurrentOneMarked() throws {
        try withTemporaryFolder { folder in
            let registry = try ProfileRegistry(
                fileURL: folder.appendingPathComponent("Profiles.json"), dataRoot: folder)
            try registry.create(name: "Work")
            try registry.create(name: "Personal", isPersistent: false)
            let choices = registry.choices(current: SidebarProfileID("WORK"))
            #expect(choices.map(\.name) == ["Default", "Work", "Personal"])
            #expect(choices.map(\.isCurrent) == [false, true, false])
            #expect(registry.choices(current: "unknown").allSatisfy { !$0.isCurrent })
        }
    }
}
