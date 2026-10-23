import Foundation
import Testing

@testable import BowCore

@Suite struct SidebarFolderTests {
    /// client/project/phase/[A] in the pinned section.
    private func clientTree() throws -> SidebarGraph {
        try SidebarGraph.sample().applying([
            .insert(.folder(id: "client", title: "client"), parent: "pinned"),
            .insert(.folder(id: "project", title: "project"), parent: "client"),
            .insert(.folder(id: "phase", title: "phase"), parent: "project"),
            .insert(.tab(id: "a", url: "https://a.example.com", title: "A"), parent: "phase"),
        ])
    }

    /// The first branch below `id` as text, for example "client/project/phase/[A]".
    private func path(_ graph: SidebarGraph, from id: SidebarItemID) -> String {
        guard let item = graph[id] else { return "?" }
        let name = item.tab.map { "[\($0.savedTitle)]" } ?? item.title ?? ""
        guard let child = item.childrenIDs.first else { return name }
        return item.data.isContainer ? path(graph, from: child) : name + "/" + path(graph, from: child)
    }

    @Test func foldersNestAndKeepTheirOrder() throws {
        let graph = try clientTree()
        #expect(graph.integrityProblems().isEmpty)
        #expect(path(graph, from: "pinned") == "client/project/phase/[A]")
        #expect(graph.isDescendant("a", of: "client"))
    }

    @Test func foldersNestWithoutADepthLimit() throws {
        var graph = SidebarGraph.sample()
        var parent: SidebarItemID = "pinned"
        for level in 0..<300 {
            let id = SidebarItemID("f\(level)")
            try graph.apply(.insert(.folder(id: id, title: "f\(level)"), parent: parent))
            parent = id
        }
        try graph.apply(.insert(.tab(id: "leaf", url: "https://leaf.example.com"), parent: parent))
        #expect(graph.integrityProblems().isEmpty)
        #expect(graph.isDescendant("leaf", of: "f0"))
        #expect(graph.orderedIDs().count == 3 + 300 + 1)
        // Moving the whole stack keeps every level.
        try graph.apply(.move("f0", parent: "unpinned"))
        #expect(graph.integrityProblems().isEmpty)
        #expect(graph.isDescendant("leaf", of: "unpinned"))
    }

    @Test func movesBetweenLevelsAndPositions() throws {
        var graph = try clientTree().applying([
            .insert(.tab(id: "b", url: "https://b.example.com", title: "B"), parent: "client"),
            .insert(.tab(id: "c", url: "https://c.example.com", title: "C"), parent: "project", index: 0),
        ])
        #expect(graph["project"]?.childrenIDs == ["c", "phase"])
        try graph.apply(.move("a", parent: "client", index: 0))
        #expect(graph["client"]?.childrenIDs == ["a", "project", "b"])
        #expect(graph["phase"]?.childrenIDs == [])
        try graph.apply(.move("phase", parent: "pinned", index: 0))
        #expect(graph["pinned"]?.childrenIDs == ["phase", "client"])
        try graph.apply(.move("project", parent: "phase"))
        #expect(graph["phase"]?.childrenIDs == ["project"])
        #expect(graph["project"]?.childrenIDs == ["c"])
        #expect(graph.integrityProblems().isEmpty)
    }

    @Test func moveRefusesCyclesAtEveryDepthAndChangesNothing() throws {
        var graph = try clientTree()
        let before = graph
        #expect(throws: SidebarStoreError.self) { try graph.apply(.move("client", parent: "client")) }
        #expect(throws: SidebarStoreError.self) { try graph.apply(.move("client", parent: "project")) }
        #expect(throws: SidebarStoreError.self) { try graph.apply(.move("client", parent: "phase")) }
        #expect(throws: SidebarStoreError.self) { try graph.apply(.move("project", parent: "phase")) }
        #expect(graph == before)
    }

    @Test func movesAcrossSpaces() throws {
        var graph = try clientTree().applying([.insertSpace("two", title: "Two")])
        let otherPinned = try #require(graph.space("two")?.pinnedContainerID)
        try graph.apply(.move("client", parent: otherPinned))
        #expect(graph["pinned"]?.childrenIDs == [])
        #expect(graph["client"]?.parentID == otherPinned)
        #expect(graph.isDescendant("a", of: otherPinned))
        #expect(graph.integrityProblems().isEmpty)
    }

    @Test func createdAndRenamedFoldersAreEmptyAndExpanded() throws {
        let graph = try SidebarGraph.sample().applying([
            .insert(.folder(id: "x", title: "Clients"), parent: "pinned"),
            .rename("x", title: "Customers"),
        ])
        #expect(graph["x"]?.title == "Customers")
        #expect(graph["x"]?.childrenIDs == [])
        #expect(graph["x"]?.data == .folder(SidebarFolder(isExpanded: true)))
    }

    @Test func deleteTakesTheFolderWithItsTabsAndFolders() throws {
        let graph = try clientTree().applying([.delete("project")])
        #expect(graph["project"] == nil && graph["phase"] == nil && graph["a"] == nil)
        #expect(graph["client"]?.childrenIDs == [])
        #expect(graph.integrityProblems().isEmpty)
    }

    @Test func deleteKeepingChildrenPutsThemInTheFoldersPlace() throws {
        var graph = try clientTree().applying([
            .insert(.tab(id: "before", url: "https://before.example.com"), parent: "client", index: 0),
            .insert(.tab(id: "after", url: "https://after.example.com"), parent: "client"),
            .insert(.tab(id: "p1", url: "https://p1.example.com"), parent: "project", index: 0),
            .setActiveTab("a"),
        ])
        try graph.apply(.deleteFolderKeepingChildren("project"))
        #expect(graph["project"] == nil)
        // The children keep their order and sit where the folder was; sub-folders keep their own contents.
        #expect(graph["client"]?.childrenIDs == ["before", "p1", "phase", "after"])
        #expect(graph["p1"]?.parentID == "client")
        #expect(graph["phase"]?.parentID == "client")
        #expect(graph["phase"]?.childrenIDs == ["a"])
        #expect(graph.activeTabID == "a")
        #expect(graph.integrityProblems().isEmpty)

        // At the top level the children land in the section itself.
        try graph.apply(.deleteFolderKeepingChildren("client"))
        #expect(graph["pinned"]?.childrenIDs == ["before", "p1", "phase", "after"])
        #expect(graph.integrityProblems().isEmpty)
    }

    @Test func deleteKeepingChildrenOfAnEmptyFolderJustRemovesIt() throws {
        let graph = try SidebarGraph.sample().applying([
            .insert(.folder(id: "empty", title: "Empty"), parent: "pinned"),
            .insert(.tab(id: "t", url: "https://t.example.com"), parent: "pinned"),
            .deleteFolderKeepingChildren("empty"),
        ])
        #expect(graph["pinned"]?.childrenIDs == ["t"])
        #expect(graph["empty"] == nil)
    }

    @Test func deleteKeepingChildrenRefusesNonFoldersAndMissingItems() throws {
        var graph = try SidebarGraph.twelveItems()
        let before = graph
        #expect(throws: SidebarStoreError.self) { try graph.apply(.deleteFolderKeepingChildren("split")) }
        #expect(throws: SidebarStoreError.self) { try graph.apply(.deleteFolderKeepingChildren("docs")) }
        #expect(throws: SidebarStoreError.self) { try graph.apply(.deleteFolderKeepingChildren("pinned")) }
        #expect(throws: SidebarStoreError.itemNotFound("nope")) {
            try graph.apply(.deleteFolderKeepingChildren("nope"))
        }
        #expect(graph == before)
    }

    @Test func treeEmptyFoldersAndCollapseStateSurviveRelaunch() throws {
        try withTemporaryFolder { folder in
            let url = SidebarStore.fileURL(inApplicationSupportFolder: folder)
            let store = try SidebarStore(fileURL: url)
            let pinned = store.graph.pinnedID
            try store.apply([
                .insert(.folder(id: "client", title: "client"), parent: pinned),
                .insert(.folder(id: "project", title: "project"), parent: "client"),
                .insert(.folder(id: "phase", title: "phase"), parent: "project"),
                .insert(.tab(id: "a", url: "https://a.example.com", title: "A"), parent: "phase"),
                .insert(.folder(id: "empty", title: "Empty"), parent: "client"),
                .setFolderExpanded("project", false),
                .setFolderExpanded("empty", false),
            ])

            let reopened = try SidebarStore(fileURL: url)
            #expect(reopened.openReport.repairs.isEmpty)
            #expect(reopened.graph == store.graph)
            #expect(path(reopened.graph, from: pinned) == "client/project/phase/[A]")
            #expect(reopened.graph["empty"]?.childrenIDs == [])
            #expect(reopened.graph["project"]?.data == .folder(SidebarFolder(isExpanded: false)))
            #expect(reopened.graph["client"]?.data == .folder(SidebarFolder(isExpanded: true)))
        }
    }

    @Test func aRefusedStepInATransactionLeavesTheStoreUntouched() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            try store.apply([.insert(.folder(id: "a", title: "A"), parent: store.graph.pinnedID)])
            let before = store.graph
            #expect(throws: SidebarStoreError.self) {
                try store.apply([
                    .insert(.folder(id: "b", title: "B"), parent: "a"),
                    .move("a", parent: "b"),
                ])
            }
            #expect(store.graph == before)
        }
    }

    @Test func repairKeepsEmptyFoldersAndCollapsedState() throws {
        var graph = try clientTree().applying([
            .insert(.folder(id: "empty", title: "Empty"), parent: "pinned"),
            .setFolderExpanded("client", false),
        ])
        // Damage something unrelated so repair has work to do.
        graph.items["pinned"]?.childrenIDs.append("ghost")
        let repairs = graph.repair()
        #expect(!repairs.isEmpty)
        #expect(graph["empty"]?.childrenIDs == [])
        #expect(graph["client"]?.data == .folder(SidebarFolder(isExpanded: false)))
        #expect(graph.integrityProblems().isEmpty)
    }
}
