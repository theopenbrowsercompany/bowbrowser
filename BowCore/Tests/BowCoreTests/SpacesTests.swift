import Foundation
import Testing

@testable import BowCore

@Suite struct SpacesTests {
    /// A store on a temporary file holding Spaces "work" (tabs A and B, A pinned) and "personal" (tab C).
    private func makeStore(in folder: URL) throws -> SidebarStore {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let first = store.graph.spaces[0]
        try store.renameSpace(first.id, to: "work")
        let personal = try store.createSpace(title: "personal", activate: false)
        let second = try #require(store.graph.space(personal))
        try store.apply([
            .insert(.tab(id: "A", url: "https://a.example"), parent: first.pinnedContainerID),
            .insert(.tab(id: "B", url: "https://b.example"), parent: first.unpinnedContainerID),
            .insert(.tab(id: "C", url: "https://c.example"), parent: second.unpinnedContainerID),
            .setActiveTab("B"),
        ])
        return store
    }

    private func id(_ title: String, in store: SidebarStore) throws -> SidebarSpaceID {
        try #require(store.graph.spaces.first { $0.title == title }).id
    }

    @Test func createAddsAnEmptySpaceOnTheDefaultProfileAndSwitchesToIt() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let first = store.graph.spaces[0].id
            let created = try store.createSpace(title: "  Play \n")
            let space = try #require(store.graph.space(created))
            #expect(space.title == "Play")
            #expect(space.profileID == .default)
            #expect(store.graph.spaces.map(\.id) == [first, created])
            #expect(store.graph.activeSpaceID == created)
            #expect(store.graph.tabIDs(in: created).isEmpty)
            #expect(store.graph.children(of: space.pinnedContainerID).isEmpty)
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func createCanPlaceASpaceAndKeepTheCurrentOneOnScreen() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let first = store.graph.spaces[0].id
            let created = try store.createSpace(title: "Front", profileID: "work-profile", at: 0, activate: false)
            #expect(store.graph.spaces.map(\.id) == [created, first])
            #expect(store.graph.activeSpaceID == first)
            #expect(store.graph.space(created)?.profileID == "work-profile")
        }
    }

    @Test func aSpaceNeedsANameButNamesCanRepeat() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let before = store.graph
            #expect(throws: SidebarStoreError.emptySpaceTitle) { try store.createSpace(title: " \t\n") }
            #expect(throws: SidebarStoreError.emptySpaceTitle) { try store.renameSpace(before.spaces[0].id, to: "") }
            #expect(store.graph == before)
            try store.createSpace(title: before.spaces[0].title)
            #expect(store.graph.spaces.count == 2)
        }
    }

    @Test func renameChangesOnlyTheTitleAndKeepsTheTabs() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let tabs = store.graph.tabIDs(in: work)
            try store.renameSpace(work, to: " Job ")
            #expect(store.graph.space(work)?.title == "Job")
            #expect(store.graph.tabIDs(in: work) == tabs)
            #expect(throws: SidebarStoreError.spaceNotFound("nowhere")) { try store.renameSpace("nowhere", to: "x") }
        }
    }

    @Test func deleteRemovesTheSpaceAndItsTabsAndReportsThemForClosing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            #expect(store.graph.activeSpaceID == work)

            let closed = try store.deleteSpace(work)
            #expect(closed == ["A", "B"])
            #expect(store.graph.spaces.map(\.id) == [personal])
            #expect(store.graph["A"] == nil && store.graph["B"] == nil)
            // The Space that took its place is on screen with its own tab selected.
            #expect(store.graph.activeSpaceID == personal)
            #expect(store.graph.activeTabID == "C")
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func aWindowAlwaysKeepsAtLeastOneSpace() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let only = store.graph.spaces[0].id
            #expect(throws: SidebarStoreError.lastSpace) { try store.deleteSpace(only) }
            #expect(store.graph.spaces.map(\.id) == [only])
        }
    }

    @Test func deletingTheLastSpaceInTheListMovesToThePreviousOne() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            try store.switchToSpace(personal)
            try store.deleteSpace(personal)
            #expect(store.graph.activeSpaceID == work)
            #expect(store.graph.activeTabID == "B")
        }
    }

    @Test func switchingShowsOnlyTheSpacesOwnTabs() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            #expect(store.graph.tabIDs(in: work) == ["A", "B"])  // pinned first
            #expect(store.graph.tabIDs(in: personal) == ["C"])

            try store.switchToSpace(personal)
            #expect(store.graph.activeSpaceID == personal)
            #expect(store.graph.activeTabID == "C")
            #expect(store.graph.tabIDs(in: store.graph.activeSpaceID!) == ["C"])
            #expect(store.graph.spaceID(containing: "C") == personal)
            #expect(store.graph.spaceID(containing: "A") == work)
        }
    }

    @Test func eachSpaceRemembersItsSelectedTabAndTabsInFoldersCount() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            let workSpace = try #require(store.graph.space(work))
            try store.apply([
                .insert(.folder(id: "f", title: "Folder"), parent: workSpace.unpinnedContainerID),
                .insert(.tab(id: "D", url: "https://d.example"), parent: "f"),
            ])
            try store.selectTab("D")
            try store.switchToSpace(personal)
            try store.switchToSpace(work)
            #expect(store.graph.activeTabID == "D")
            #expect(store.graph.tabIDs(in: work) == ["A", "B", "D"])
        }
    }

    @Test func switchingToTheShownSpaceChangesNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            try store.switchToSpace(before.activeSpaceID!)
            #expect(store.graph == before)
        }
    }

    @Test func switchRefusesAnUnknownSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let before = store.graph
            #expect(throws: SidebarStoreError.spaceNotFound("nowhere")) { try store.switchToSpace("nowhere") }
            #expect(store.graph == before)
        }
    }

    @Test func numberShortcutsReachTheNthSpaceAndIgnoreMissingOnes() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            #expect(try store.switchToSpace(shortcutNumber: 2) == personal)
            #expect(store.graph.activeSpaceID == personal)
            #expect(try store.switchToSpace(shortcutNumber: 1) == work)
            for number in [3, 9, 0, 10, -1] {
                #expect(try store.switchToSpace(shortcutNumber: number) == nil)
                #expect(store.graph.activeSpaceID == work)
            }
        }
    }

    @Test func swipeMovesToTheNeighbourAndStopsAtTheEnds() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            #expect(try store.switchToAdjacentSpace(.previous) == nil)  // clamps, never wraps
            #expect(store.graph.activeSpaceID == work)
            #expect(try store.switchToAdjacentSpace(.next) == personal)
            #expect(try store.switchToAdjacentSpace(.next) == nil)
            #expect(store.graph.activeSpaceID == personal)
            #expect(try store.switchToAdjacentSpace(.previous) == work)
        }
    }

    @Test func movingATabToAnotherSpaceKeepsTheViewedSpaceAndFixesTheSelection() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            #expect(store.graph.activeTabID == "B")

            try store.moveToSpace("B", space: personal)
            #expect(store.graph.tabIDs(in: personal) == ["C", "B"])
            #expect(store.graph.tabIDs(in: work) == ["A"])
            #expect(store.graph.spaceID(containing: "B") == personal)
            // The tab left the Space on screen, so that Space selects its own tab; nothing switched.
            #expect(store.graph.activeSpaceID == work)
            #expect(store.graph.activeTabID == "A")
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func movingATabChoosesTheSectionAndPosition() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            try store.moveToSpace("A", space: personal, section: .pinned)
            let target = try #require(store.graph.space(personal))
            #expect(store.graph["A"]?.parentID == target.pinnedContainerID)
            #expect(store.graph.tabIDs(in: personal) == ["A", "C"])
            try store.moveToSpace("C", space: work, section: .unpinned, index: 0)
            let source = try #require(store.graph.space(work))
            #expect(store.graph.children(of: source.unpinnedContainerID).map(\.id) == ["C", "B"])
        }
    }

    @Test func movingAFolderCarriesItsTabsAndRefusesAnUnknownSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            let workSpace = try #require(store.graph.space(work))
            try store.apply([
                .insert(.folder(id: "f", title: "Folder"), parent: workSpace.unpinnedContainerID),
                .insert(.tab(id: "D", url: "https://d.example"), parent: "f"),
            ])
            try store.moveToSpace("f", space: personal)
            #expect(store.graph.tabIDs(in: personal) == ["C", "D"])
            #expect(store.graph.tabIDs(in: work) == ["A", "B"])

            let before = store.graph
            #expect(throws: SidebarStoreError.spaceNotFound("nowhere")) { try store.moveToSpace("A", space: "nowhere") }
            #expect(throws: SidebarStoreError.self) { try store.moveToSpace("nowhere", space: work) }
            #expect(throws: SidebarStoreError.self) { try store.moveToSpace(workSpace.pinnedContainerID, space: work) }
            #expect(store.graph == before)
        }
    }

    @Test func selectingATabInAnotherSpaceSwitchesToThatSpace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let personal = try id("personal", in: store)
            try store.selectTab("C")
            #expect(store.graph.activeSpaceID == personal)
            #expect(store.graph.activeTabID == "C")
        }
    }

    @Test func aFavoritesTabStaysSelectedWhenSwitching() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let personal = try id("personal", in: store)
            try store.apply([
                .insert(.tab(id: "fav", url: "https://fav.example"), parent: store.graph.favoritesContainerID)
            ])
            try store.selectTab("fav")
            try store.switchToSpace(personal)
            #expect(store.graph.activeTabID == "fav")
        }
    }

    @Test func spacesAndTheirProfileSurviveARelaunch() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("Sidebar.json")
            let store = try makeStore(in: folder)
            let work = try id("work", in: store)
            let personal = try id("personal", in: store)
            try store.switchToSpace(personal)
            try store.switchToSpace(work)
            try store.switchToSpace(personal)
            let reopened = try SidebarStore(fileURL: url)
            #expect(reopened.graph == store.graph)
            #expect(reopened.openReport.repairs.isEmpty)
            #expect(reopened.graph.space(work)?.lastSelectedTabID == "B")
            #expect(reopened.graph.space(work)?.profileID == .default)
        }
    }

    @Test func aSpaceSavedBeforeProfilesExistedReadsAsTheDefaultProfile() throws {
        let json = #"{"id":"s","title":"Old","pinnedContainerID":"p","unpinnedContainerID":"u"}"#
        let space = try JSONDecoder().decode(SidebarSpace.self, from: Data(json.utf8))
        #expect(space.profileID == .default)
        #expect(space.lastSelectedTabID == nil)
    }
}
