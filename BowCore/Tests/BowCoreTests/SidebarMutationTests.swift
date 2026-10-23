import Foundation
import Testing

@testable import BowCore

@Suite struct SidebarMutationTests {
    @Test func freshGraphIsSoundAndHasOneEmptySpace() {
        let graph = SidebarGraph.fresh()
        #expect(graph.integrityProblems().isEmpty)
        #expect(graph.spaces.count == 1)
        #expect(graph.activeSpaceID == graph.spaces[0].id)
        #expect(graph.contentItemCount == 0)
    }

    @Test func insertKeepsBothDirectionsOfTheHierarchyInStep() throws {
        let graph = try SidebarGraph.twelveItems()
        #expect(graph.integrityProblems().isEmpty)
        #expect(graph.contentItemCount == 12)
        #expect(graph["docs"]?.parentID == "work")
        #expect(graph["work"]?.childrenIDs == ["docs", "deep"])
        #expect(graph["pinned"]?.childrenIDs == ["work", "split", "renamed"])
    }

    @Test func insertAtAnIndex() throws {
        let graph = try SidebarGraph.twelveItems().applying([
            .insert(.tab(id: "first", url: "https://a.example"), parent: "unpinned", index: 0)
        ])
        #expect(graph["unpinned"]?.childrenIDs == ["first", "news", "search"])
    }

    @Test func insertRefusesDuplicatesBadParentsAndBadIndexes() throws {
        var graph = try SidebarGraph.twelveItems()
        let before = graph
        #expect(throws: SidebarStoreError.itemAlreadyExists("docs")) {
            try graph.apply(.insert(.tab(id: "docs", url: "x"), parent: "pinned"))
        }
        #expect(throws: SidebarStoreError.itemNotFound("nowhere")) {
            try graph.apply(.insert(.tab(url: "x"), parent: "nowhere"))
        }
        #expect(throws: SidebarStoreError.invalidIndex(9)) {
            try graph.apply(.insert(.tab(url: "x"), parent: "pinned", index: 9))
        }
        // Tabs hold nothing, splits hold only tabs, and sections never nest.
        for (item, parent) in [
            (SidebarItem.tab(url: "x"), SidebarItemID("docs")),
            (SidebarItem.folder(title: "f"), "split"),
            (SidebarItem(data: .container(SidebarContainer(kind: .pinned))), "work"),
        ] {
            #expect(throws: SidebarStoreError.self) { try graph.apply(.insert(item, parent: parent)) }
        }
        var withChildren = SidebarItem.folder(id: "with-children", title: "f")
        withChildren.childrenIDs = ["docs"]
        #expect(throws: SidebarStoreError.self) { try graph.apply(.insert(withChildren, parent: "pinned")) }
        #expect(graph == before)
    }

    @Test func moveCarriesTheSubtreeAndCountsTheIndexAfterRemoval() throws {
        let graph = try SidebarGraph.twelveItems().applying([
            .move("deep", parent: "unpinned", index: 1),
            .move("renamed", parent: "pinned", index: 0),
        ])
        #expect(graph.integrityProblems().isEmpty)
        #expect(graph["deep"]?.parentID == "unpinned")
        #expect(graph["deep"]?.childrenIDs == ["deep-tab"])
        #expect(graph["work"]?.childrenIDs == ["docs"])
        #expect(graph["unpinned"]?.childrenIDs == ["news", "deep", "search"])
        #expect(graph["pinned"]?.childrenIDs == ["renamed", "work", "split"])
    }

    @Test func moveWithinTheSameParentReorders() throws {
        let graph = try SidebarGraph.twelveItems().applying([.move("news", parent: "unpinned", index: 1)])
        #expect(graph["unpinned"]?.childrenIDs == ["search", "news"])
    }

    @Test func moveRefusesLoopsSectionsAndBadIndexesWithoutChangingAnything() throws {
        var graph = try SidebarGraph.twelveItems()
        let before = graph
        #expect(throws: SidebarStoreError.self) { try graph.apply(.move("work", parent: "deep")) }
        #expect(throws: SidebarStoreError.self) { try graph.apply(.move("work", parent: "work")) }
        #expect(throws: SidebarStoreError.self) { try graph.apply(.move("pinned", parent: "work")) }
        #expect(throws: SidebarStoreError.invalidIndex(5)) { try graph.apply(.move("news", parent: "work", index: 5)) }
        #expect(graph == before)
    }

    @Test func deleteRemovesTheWholeSubtreeAndClearsTheActiveTab() throws {
        let graph = try SidebarGraph.twelveItems().applying([.setActiveTab("deep-tab"), .delete("work")])
        #expect(graph.integrityProblems().isEmpty)
        for id: SidebarItemID in ["work", "docs", "deep", "deep-tab"] { #expect(graph[id] == nil) }
        #expect(graph["pinned"]?.childrenIDs == ["split", "renamed"])
        #expect(graph.activeTabID == nil)
        var copy = graph
        #expect(throws: SidebarStoreError.self) { try copy.apply(.delete("pinned")) }
    }

    @Test func editsTitlesSavedPagesFoldersAndSplits() throws {
        let graph = try SidebarGraph.twelveItems().applying([
            .rename("work", title: "Job"),
            .rename("renamed", title: nil),
            .setSavedPage("docs", url: "https://docs.example.com/new", title: "New"),
            .setFolderExpanded("work", false),
            .setSplitOrientation("split", .horizontal),
        ])
        #expect(graph["work"]?.title == "Job")
        #expect(graph["renamed"]?.title == nil)
        #expect(graph["docs"]?.tab == SidebarTab(savedURL: "https://docs.example.com/new", savedTitle: "New"))
        #expect(graph["work"]?.data == .folder(SidebarFolder(isExpanded: false)))
        #expect(graph["split"]?.data == .split(SidebarSplit(orientation: .horizontal)))
        var copy = graph
        #expect(throws: SidebarStoreError.self) { try copy.apply(.setSavedPage("work", url: "x", title: "x")) }
        #expect(throws: SidebarStoreError.self) { try copy.apply(.setFolderExpanded("docs", true)) }
        #expect(throws: SidebarStoreError.self) { try copy.apply(.setActiveTab("work")) }
    }

    @Test func spacesAreAddedMovedRenamedAndDeletedWithTheirSections() throws {
        var graph = try SidebarGraph.twelveItems().applying([
            .insertSpace("work-space", title: "Work"),
            .insertSpace("play", title: "Play", index: 0),
            .renameSpace("work-space", title: "Job"),
            .moveSpace("play", index: 2),
        ])
        #expect(graph.spaces.map(\.id) == ["home", "work-space", "play"])
        #expect(graph.space("work-space")?.title == "Job")
        #expect(graph.integrityProblems().isEmpty)

        let play = try #require(graph.space("play"))
        graph = try graph.applying([
            .insert(.tab(id: "game", url: "https://game.example"), parent: play.pinnedContainerID),
            .setActiveSpace("play"),
            .setActiveTab("game"),
            .deleteSpace("play"),
        ])
        #expect(graph.spaces.map(\.id) == ["home", "work-space"])
        #expect(graph[play.pinnedContainerID] == nil)
        #expect(graph["game"] == nil)
        #expect(graph.activeSpaceID == "work-space")
        #expect(graph.activeTabID == nil)
        #expect(graph.integrityProblems().isEmpty)

        #expect(throws: SidebarStoreError.spaceAlreadyExists("home")) {
            try graph.apply(.insertSpace("home", title: "Again"))
        }
        #expect(throws: SidebarStoreError.spaceNotFound("gone")) { try graph.apply(.renameSpace("gone", title: "x")) }
        #expect(throws: SidebarStoreError.invalidIndex(7)) { try graph.apply(.moveSpace("home", index: 7)) }
        graph = try graph.applying([.deleteSpace("work-space")])
        #expect(throws: SidebarStoreError.lastSpace) { try graph.apply(.deleteSpace("home")) }
    }

    @Test func launchLoadsOnlyTheActiveTab() throws {
        let graph = try SidebarGraph.twelveItems()
        let plan = graph.launchPlan()
        #expect(plan.loadNow == "news")
        #expect(
            plan.loadOnSelect == [
                "fav-mail", "fav-cal", "docs", "deep-tab", "left", "right", "renamed", "search",
            ])

        let none = try graph.applying([.setActiveTab(nil)]).launchPlan()
        #expect(none.loadNow == nil)
        #expect(none.loadOnSelect.count == 9)
    }
}
