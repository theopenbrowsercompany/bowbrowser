import Foundation
import Testing

@testable import BowCore

@Suite struct CollapseAllTests {
    /// Space "home" (on screen). Pinned: folder "client" > folder "project" > folder "phase" > tab "a", with tab
    /// "client-note" beside "project"; folder "empty". Tabs section: folder "reading" > split "pair" > tabs "p1", "p2";
    /// folder "later" > tab "b"; tab "loose". Space "play": folder "games" > tab "g".
    private func makeStore(in folder: URL, active: SidebarItemID? = "a") throws -> SidebarStore {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let home = store.graph.firstSpace
        let play = try store.createSpace(title: "play", activate: false)
        let playSpace = try #require(store.graph.space(play))
        try store.apply([
            .insert(.folder(id: "client", title: "client"), parent: home.pinnedContainerID),
            .insert(.folder(id: "project", title: "project"), parent: "client"),
            .insert(.folder(id: "phase", title: "phase"), parent: "project"),
            .insert(.tab(id: "a", url: "https://a.example.com", title: "A"), parent: "phase"),
            .insert(.tab(id: "client-note", url: "https://note.example.com"), parent: "client"),
            .insert(.folder(id: "empty", title: "empty"), parent: home.pinnedContainerID),
            .insert(.folder(id: "reading", title: "reading"), parent: home.unpinnedContainerID),
            .insert(.split(id: "pair"), parent: "reading"),
            .insert(.tab(id: "p1", url: "https://p1.example.com"), parent: "pair"),
            .insert(.tab(id: "p2", url: "https://p2.example.com"), parent: "pair"),
            .insert(.folder(id: "later", title: "later"), parent: home.unpinnedContainerID),
            .insert(.tab(id: "b", url: "https://b.example.com", title: "B"), parent: "later"),
            .insert(.tab(id: "loose", url: "https://loose.example.com"), parent: home.unpinnedContainerID),
            .insert(.folder(id: "games", title: "games"), parent: playSpace.pinnedContainerID),
            .insert(.tab(id: "g", url: "https://g.example.com"), parent: "games"),
            .setActiveTab(active),
        ])
        return store
    }

    private func isExpanded(_ store: SidebarStore, _ id: SidebarItemID) -> Bool? {
        if case .folder(let folder)? = store.graph[id]?.data { return folder.isExpanded }
        return nil
    }

    private func visibleIDs(_ store: SidebarStore) -> [SidebarItemID] {
        store.graph.visibleRows(in: store.graph.firstSpace.id).map(\.id)
    }

    @Test func collapsingKeepsThePathToTheActiveTabOpen() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(try store.collapseAllFolders() == 3)
            for open in ["client", "project", "phase"] as [SidebarItemID] { #expect(isExpanded(store, open) == true) }
            for closed in ["empty", "reading", "later"] as [SidebarItemID] {
                #expect(isExpanded(store, closed) == false)
            }
            #expect(store.graph.isVisible("a"))
            #expect(!store.graph.isVisible("b"))
            #expect(
                visibleIDs(store) == [
                    "client", "project", "phase", "a", "client-note", "empty", "reading", "later", "loose",
                ])
        }
    }

    @Test func foldersOffThePathCollapseAtEveryDepth() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder, active: "client-note")
            // Only "client" is on the path; "project" and "phase" below it close, hiding "a".
            #expect(try store.collapseAllFolders() == 5)
            #expect(isExpanded(store, "client") == true)
            #expect(isExpanded(store, "project") == false)
            #expect(isExpanded(store, "phase") == false)
            #expect(visibleIDs(store) == ["client", "project", "client-note", "empty", "reading", "later", "loose"])
        }
    }

    @Test func aCollapsedAncestorOfTheActiveTabOpensAgain() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder, active: "b")
            try store.apply([.setFolderExpanded("later", false), .setFolderExpanded("project", false)])
            #expect(!store.graph.isVisible("b"))
            // "later" was closed and is opened again; "project" was already closed. Neither counts as collapsed.
            #expect(try store.collapseAllFolders() == 4)
            #expect(isExpanded(store, "later") == true)
            #expect(store.graph.isVisible("b"))
            #expect(isExpanded(store, "client") == false)
            #expect(isExpanded(store, "project") == false)
        }
    }

    @Test func aTabInASplitKeepsItsFoldersOpen() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder, active: "p2")
            #expect(try store.collapseAllFolders() == 5)
            #expect(isExpanded(store, "reading") == true)
            #expect(store.graph.isVisible("p2"))
            #expect(store.graph.isVisible("p1"))
        }
    }

    @Test(arguments: [nil, "g", "loose"] as [SidebarItemID?])
    func withoutAnActiveTabInTheSpaceEveryFolderCollapses(active: SidebarItemID?) throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder, active: active)
            #expect(try store.collapseAllFolders() == 6)
            for id in ["client", "project", "phase", "empty", "reading", "later"] as [SidebarItemID] {
                #expect(isExpanded(store, id) == false)
            }
            // The other Space is untouched.
            #expect(isExpanded(store, "games") == true)
        }
    }

    @Test func aFavoriteActiveTabDoesNotKeepAnythingOpen() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let favorites = try #require(store.graph.favoritesContainerID(for: .default))
            try store.apply([
                .insert(.tab(id: "fav", url: "https://fav.example.com"), parent: favorites), .setActiveTab("fav"),
            ])
            #expect(try store.collapseAllFolders() == 6)
        }
    }

    @Test func collapsingASpaceLeavesTheOthersAndTargetsTheGivenSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let play = try #require(store.graph.spaces.last).id
            #expect(try store.collapseAllFolders(in: play) == 1)
            #expect(isExpanded(store, "games") == false)
            #expect(isExpanded(store, "client") == true)
            #expect(try store.collapseAllFolders(in: play) == 0)
            #expect(throws: SidebarStoreError.spaceNotFound("nope")) { try store.collapseAllFolders(in: "nope") }
        }
    }

    @Test func collapsingTwiceChangesNothingTheSecondTime() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.collapseAllFolders()
            try store.save()
            let before = store.graph
            #expect(try store.collapseAllFolders() == 0)
            #expect(store.graph == before)
            #expect(!store.hasUnsavedChanges)
        }
    }

    @Test func collapseStateIsSavedAndSurvivesRelaunch() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.collapseAllFolders()
            #expect(!store.hasUnsavedChanges)
            let reopened = try SidebarStore(fileURL: store.fileURL)
            #expect(reopened.graph == store.graph)
            #expect(isExpanded(reopened, "phase") == true)
            #expect(isExpanded(reopened, "later") == false)
            #expect(reopened.graph.isVisible("a"))
        }
    }

    @Test func collapsingIsRefusedInsideAnOpenTransaction() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.collapseAllFolders()
            #expect(!store.isInTransaction)
            // Starting inside an open transaction is refused and leaves the sidebar as it was.
            try store.beginTransaction()
            #expect(throws: SidebarStoreError.nestedTransaction) { try store.expandAllFolders() }
            store.rollbackTransaction()
            #expect(isExpanded(store, "later") == false)
        }
    }

    @Test func expandAllOpensEveryFolderOfTheSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.collapseAllFolders()
            #expect(try store.expandAllFolders() == 3)
            for id in ["client", "project", "phase", "empty", "reading", "later"] as [SidebarItemID] {
                #expect(isExpanded(store, id) == true)
            }
            #expect(try store.expandAllFolders() == 0)
        }
    }

    @Test func visibleRowsListSectionsInOrderWithDepth() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder, active: nil)
            let space = store.graph.firstSpace.id
            let rows = store.graph.visibleRows(in: space)
            #expect(rows.first == SidebarRow(id: "client", depth: 0))
            #expect(rows.contains(SidebarRow(id: "a", depth: 3)))
            #expect(rows.contains(SidebarRow(id: "p1", depth: 2)))
            #expect(rows.last == SidebarRow(id: "loose", depth: 0))
            #expect(!rows.contains { $0.id == "g" })
            try store.collapseAllFolders()
            #expect(
                store.graph.visibleRows(in: space)
                    == ["client", "empty", "reading", "later", "loose"].map { SidebarRow(id: $0, depth: 0) })
            #expect(store.graph.visibleRows(in: "nope").isEmpty)
            #expect(!store.graph.isVisible("a"))
            #expect(!store.graph.isVisible("pinned"))
        }
    }
}
