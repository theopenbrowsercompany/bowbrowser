import Foundation
import Testing

@testable import BowCore

@Suite struct SplitViewTests {
    /// A store whose unpinned section holds tabs a to e, a folder with tab in-folder, and the pinned section holds
    /// tab p; a Favorite f. Tab "a" is selected.
    private func makeStore(in folder: URL) throws -> SidebarStore {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let space = store.graph.spaces[0]
        var mutations: [SidebarMutation] = ["a", "b", "c", "d", "e"].map {
            .insert(
                .tab(id: SidebarItemID($0), url: "https://\($0).example.com", title: $0),
                parent: space.unpinnedContainerID)
        }
        mutations += [
            .insert(.folder(id: "folder", title: "Folder"), parent: space.unpinnedContainerID),
            .insert(.tab(id: "in-folder", url: "https://in-folder.example.com"), parent: "folder"),
            .insert(.tab(id: "p", url: "https://p.example.com"), parent: space.pinnedContainerID),
            .insert(
                .tab(id: "f", url: "https://f.example.com"),
                parent: try #require(store.graph.favoritesContainerID(for: .default))),
            .setActiveTab("a"),
        ]
        try store.apply(mutations)
        return store
    }

    private func unpinnedOrder(_ store: SidebarStore) -> [SidebarItemID] {
        store.graph.children(of: store.graph.spaces[0].unpinnedContainerID).map(\.id)
    }

    private func expectRefused(_ store: SidebarStore, _ body: () throws -> Void) {
        let before = store.graph
        #expect(throws: SidebarStoreError.self) { try body() }
        #expect(store.graph == before)
    }

    private func sum(_ values: [Double]) -> Double { values.reduce(0, +) }

    private func approximately(_ actual: [Double], _ expected: [Double]) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    // MARK: create

    @Test func createsASplitInTheFirstTabsPlaceWithEqualWidthsAndFocusOnTheFirstPane() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let id = try store.createSplit(from: ["b", "d", "c"], orientation: .vertical, id: "s")
            #expect(id == "s")
            #expect(unpinnedOrder(store) == ["a", "s", "e", "folder"])
            #expect(store.graph.splitPaneIDs("s") == ["b", "d", "c"])
            #expect(store.graph.split("s")?.orientation == .vertical)
            #expect(store.graph.splitWidthFractions("s").allSatisfy { abs($0 - 1.0 / 3) < 1e-12 })
            #expect(store.graph.focusedSplitPaneID("s") == "b")
            #expect(store.graph.splitID(containing: "d") == "s")
            #expect(store.graph.integrityProblems().isEmpty)
            #expect(store.graph.activeTabID == "a")
        }
    }

    @Test func aSplitOfFourTabsCanFocusAnyPane() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c", "d"], focusing: "c", id: "s")
            #expect(store.graph.focusedSplitPaneID("s") == "c")
            #expect(unpinnedOrder(store) == ["s", "e", "folder"])
        }
    }

    @Test func aSplitInAFolderStaysInTheFolder() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.apply([.insert(.tab(id: "g", url: "https://g.example.com"), parent: "folder")])
            try store.createSplit(from: ["in-folder", "g"], id: "s")
            #expect(store.graph["folder"]?.childrenIDs == ["s"])
        }
    }

    @Test func refusesSplitsThatBreakTheTwoToFourRuleOrCrossSections() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            expectRefused(store) { try store.createSplit(from: ["a"]) }
            expectRefused(store) { try store.createSplit(from: []) }
            expectRefused(store) { try store.createSplit(from: ["a", "b", "c", "d", "e"]) }
            expectRefused(store) { try store.createSplit(from: ["a", "a"]) }
            expectRefused(store) { try store.createSplit(from: ["a", "folder"]) }
            expectRefused(store) { try store.createSplit(from: ["a", "missing"]) }
            expectRefused(store) { try store.createSplit(from: ["a", "f"]) }
            expectRefused(store) { try store.createSplit(from: ["a", "p"]) }
            expectRefused(store) { try store.createSplit(from: ["a", "b"], focusing: "c") }
            try store.createSplit(from: ["a", "b"], id: "s")
            expectRefused(store) { try store.createSplit(from: ["b", "c"]) }
            expectRefused(store) { try store.createSplit(from: ["c", "d"], id: "s") }
        }
    }

    // MARK: add pane

    @Test func addingAPaneGivesItAnEqualShareAndKeepsFocus() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b"], id: "s")
            try store.setSplitWidthFactors("s", [3, 1])
            try store.addPane("c", to: "s")
            #expect(store.graph.splitPaneIDs("s") == ["a", "b", "c"])
            let fractions = store.graph.splitWidthFractions("s")
            #expect(abs(sum(fractions) - 1) < 1e-12)
            #expect(abs(fractions[2] - 1.0 / 3) < 1e-12)
            #expect(abs(fractions[0] / fractions[1] - 3) < 1e-9)
            #expect(store.graph.focusedSplitPaneID("s") == "a")

            try store.addPane("d", to: "s", at: 0)
            #expect(store.graph.splitPaneIDs("s") == ["d", "a", "b", "c"])
            #expect(abs(store.graph.splitWidthFractions("s")[0] - 0.25) < 1e-12)
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func aFifthPaneAndOtherBadAdditionsAreRefused() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c", "d"], id: "s")
            expectRefused(store) { try store.addPane("e", to: "s") }

            try store.removePane("d")
            expectRefused(store) { try store.addPane("b", to: "s") }  // already a pane
            expectRefused(store) { try store.addPane("f", to: "s") }  // a Favorite
            expectRefused(store) { try store.addPane("p", to: "s") }  // another section
            expectRefused(store) { try store.addPane("folder", to: "s") }
            expectRefused(store) { try store.addPane("e", to: "a") }  // not a split
            expectRefused(store) { try store.addPane("e", to: "s", at: 9) }
        }
    }

    @Test func theGenericMutationsAlsoStopAtFourPanes() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c", "d"], id: "s")
            expectRefused(store) { try store.apply([.move("e", parent: "s")]) }
            expectRefused(store) { try store.apply([.insert(.tab(id: "x", url: "https://x"), parent: "s")]) }
            // Reordering inside a full split is still fine.
            try store.apply([.move("a", parent: "s", index: 3)])
            #expect(store.graph.splitPaneIDs("s") == ["b", "c", "d", "a"])
        }
    }

    // MARK: remove pane

    @Test func removingAPaneSharesItsWidthAndMovesFocusToItsNeighbour() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c"], id: "s")
            try store.setSplitWidthFactors("s", [2, 1, 1])
            try store.setFocusedPane("b")
            #expect(try store.removePane("b"))
            #expect(store.graph.splitPaneIDs("s") == ["a", "c"])
            #expect(approximately(store.graph.splitWidthFractions("s"), [2.0 / 3, 1.0 / 3]))
            #expect(store.graph.focusedSplitPaneID("s") == "a")
            // The pane left as a plain tab right after the split.
            #expect(unpinnedOrder(store) == ["s", "b", "d", "e", "folder"])
            #expect(store.graph.splitID(containing: "b") == nil)
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func aSplitLeftWithOneTabBecomesThatTabAgain() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            #expect(try store.removePane("b") == false)
            #expect(store.graph["s"] == nil)
            #expect(unpinnedOrder(store) == ["a", "c", "b", "d", "e", "folder"])
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func closingAPaneDeletesItsTabAndDissolvesASplitOfTwo() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.apply([.setActiveTab("c")])
            #expect(try store.removePane("c", closing: true) == false)
            #expect(store.graph["c"] == nil && store.graph["s"] == nil)
            #expect(unpinnedOrder(store) == ["a", "b", "d", "e", "folder"])
            #expect(store.graph.activeTabID != "c")  // choosing the next tab is the tab model's job
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func closingAPaneOfALargerSplitKeepsTheSplit() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c"], id: "s")
            #expect(try store.removePane("a", closing: true))
            #expect(store.graph.splitPaneIDs("s") == ["b", "c"])
            #expect(store.graph.focusedSplitPaneID("s") == "b")
        }
    }

    @Test func removingATabThatIsNotAPaneIsRefused() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            expectRefused(store) { try store.removePane("a") }
        }
    }

    // MARK: separate

    @Test func separatingASplitLeavesItsTabsInPlaceInOrder() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "d", "c"], id: "s")
            #expect(try store.separateSplit("s") == ["b", "d", "c"])
            #expect(unpinnedOrder(store) == ["a", "b", "d", "c", "e", "folder"])
            #expect(store.graph["s"] == nil)
            #expect(store.graph.integrityProblems().isEmpty)
            expectRefused(store) { try store.separateSplit("a") }
            expectRefused(store) { try store.separateSplit("s") }
        }
    }

    @Test func aPinnedSplitSeparatesIntoPinnedTabs() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let pinned = store.graph.spaces[0].pinnedContainerID
            try store.apply([.insert(.tab(id: "q", url: "https://q.example.com"), parent: pinned)])
            try store.createSplit(from: ["p", "q"], id: "s")
            #expect(store.graph.isPinned("p") && store.graph.isPinned("q"))
            try store.separateSplit("s")
            #expect(store.graph["s"] == nil)
            #expect(store.graph.children(of: pinned).map(\.id) == ["p", "q"])
        }
    }

    // MARK: resize, focus, orientation, order

    @Test func widthFactorsNormalizeAndBadOnesAreRefused() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c"], id: "s")
            try store.setSplitWidthFactors("s", [2, 1, 1])
            #expect(approximately(store.graph.splitWidthFractions("s"), [0.5, 0.25, 0.25]))
            #expect(approximately(store.graph.split("s")?.widthFactors ?? [], [0.5, 0.25, 0.25]))

            expectRefused(store) { try store.setSplitWidthFactors("s", [1, 1]) }
            expectRefused(store) { try store.setSplitWidthFactors("s", [1, 0, 1]) }
            expectRefused(store) { try store.setSplitWidthFactors("s", [1, -1, 1]) }
            expectRefused(store) { try store.setSplitWidthFactors("s", [1, .nan, 1]) }
            expectRefused(store) { try store.setSplitWidthFactors("s", [1, .infinity, 1]) }
            expectRefused(store) { try store.setSplitWidthFactors("s", [100, 1, 100]) }  // middle pane under 10%
            expectRefused(store) { try store.setSplitWidthFactors("a", [1, 1, 1]) }
        }
    }

    @Test func draggingADividerMovesOnlyTheTwoPanesBesideItAndStopsAtTheMinimum() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c"], id: "s")
            try store.setSplitWidthFactors("s", [1, 2, 1])  // 0.25, 0.5, 0.25
            try store.moveSplitDivider("s", dividerIndex: 1, to: 0.6)
            let moved = store.graph.splitWidthFractions("s")
            #expect(abs(moved[0] - 0.25) < 1e-12 && abs(moved[1] - 0.35) < 1e-12 && abs(moved[2] - 0.4) < 1e-12)

            try store.moveSplitDivider("s", dividerIndex: 1, to: 5)
            #expect(abs(store.graph.splitWidthFractions("s")[2] - SidebarSplit.minimumPaneFraction) < 1e-12)
            try store.moveSplitDivider("s", dividerIndex: 0, to: -5)
            let clamped = store.graph.splitWidthFractions("s")
            #expect(abs(clamped[0] - SidebarSplit.minimumPaneFraction) < 1e-12)
            #expect(abs(sum(clamped) - 1) < 1e-12)

            expectRefused(store) { try store.moveSplitDivider("s", dividerIndex: 2, to: 0.5) }
            expectRefused(store) { try store.moveSplitDivider("s", dividerIndex: 0, to: .nan) }
        }
    }

    @Test func focusAndOrientationChangesKeepTheRestOfTheLayout() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b"], id: "s")
            try store.setSplitWidthFactors("s", [3, 1])
            try store.setFocusedPane("b")
            try store.setSplitOrientation("s", .vertical)
            let split = try #require(store.graph.split("s"))
            #expect(split.orientation == .vertical && split.focusedItemID == "b")
            #expect(approximately(split.widthFactors, [0.75, 0.25]))
            try store.setSplitOrientation("s", .horizontal)
            #expect(approximately(store.graph.split("s")?.widthFactors ?? [], [0.75, 0.25]))
            expectRefused(store) { try store.setFocusedPane("c") }
            expectRefused(store) { try store.setSplitOrientation("a", .vertical) }
        }
    }

    @Test func movingAPaneCarriesItsWidth() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c"], id: "s")
            try store.setSplitWidthFactors("s", [1, 2, 1])
            try store.movePane("b", to: 0)
            #expect(store.graph.splitPaneIDs("s") == ["b", "a", "c"])
            #expect(approximately(store.graph.splitWidthFractions("s"), [0.5, 0.25, 0.25]))
            expectRefused(store) { try store.movePane("b", to: 3) }
            expectRefused(store) { try store.movePane("e", to: 0) }
        }
    }

    @Test func widthsThatNoLongerFitThePanesReadAsEqual() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b"], id: "s")
            try store.setSplitWidthFactors("s", [3, 1])
            // A generic move changes the pane count without touching the factors.
            try store.apply([.move("c", parent: "s")])
            #expect(store.graph.splitWidthFractions("s").allSatisfy { abs($0 - 1.0 / 3) < 1e-12 })
            // Changing only focus does not write the stale widths back.
            try store.setFocusedPane("c")
            #expect(store.graph.split("s")?.widthFactors == [])
        }
    }

    // MARK: saving

    @Test func theSplitSurvivesQuittingAndRelaunching() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c", "d"], orientation: .vertical, focusing: "c", id: "s")
            try store.setSplitWidthFactors("s", [2, 1, 1])
            let reopened = try SidebarStore(fileURL: store.fileURL)
            #expect(reopened.openReport.repairs.isEmpty)
            #expect(reopened.graph == store.graph)
            #expect(reopened.graph.splitPaneIDs("s") == ["b", "c", "d"])
            #expect(reopened.graph.split("s")?.orientation == .vertical)
            #expect(approximately(reopened.graph.splitWidthFractions("s"), [0.5, 0.25, 0.25]))
            #expect(reopened.graph.focusedSplitPaneID("s") == "c")
        }
    }

    @Test func aSplitSavedBeforeLayoutFieldsExistedStillOpens() throws {
        let json = #"{"kind":"split","split":{"orientation":"vertical"}}"#
        let data = try JSONDecoder().decode(SidebarItemData.self, from: Data(json.utf8))
        #expect(data == .split(SidebarSplit(orientation: .vertical)))
        let damaged = #"{"kind":"split","split":{"orientation":"horizontal","widthFactors":"x","focusedItemID":5}}"#
        #expect(
            try JSONDecoder().decode(SidebarItemData.self, from: Data(damaged.utf8))
                == .split(SidebarSplit(orientation: .horizontal)))
    }

    // MARK: repair

    private func splitGraph(panes: [SidebarItemID], split: SidebarSplit = SidebarSplit()) throws -> SidebarGraph {
        var mutations: [SidebarMutation] = [
            .insert(.tab(id: "before", url: "https://before.example.com"), parent: "unpinned"),
            .insert(SidebarItem(id: "s", data: .split(split)), parent: "unpinned"),
            .insert(.tab(id: "after", url: "https://after.example.com"), parent: "unpinned"),
        ]
        for pane in panes {
            mutations.append(.insert(.tab(id: pane, url: "https://\(pane).example.com"), parent: "s"))
        }
        return try SidebarGraph.sample().applying(mutations)
    }

    private func repaired(_ graph: SidebarGraph) -> (SidebarGraph, [SidebarRepair]) {
        var copy = graph
        let log = copy.repair()
        #expect(copy.integrityProblems() == [])
        var again = copy
        #expect(again.repair().isEmpty && again == copy, "repair is idempotent")
        return (copy, log)
    }

    @Test func aSoundSplitIsLeftAlone() throws {
        let graph = try splitGraph(
            panes: ["x", "y", "z"], split: SidebarSplit(widthFactors: [0.5, 0.25, 0.25], focusedItemID: "y"))
        let (after, log) = repaired(graph)
        #expect(log.isEmpty && after == graph)
    }

    @Test func aSplitWithNoTabsIsRemovedNotShown() throws {
        let (after, log) = repaired(try splitGraph(panes: []))
        #expect(after["s"] == nil)
        #expect(after["unpinned"]?.childrenIDs == ["before", "after"])
        #expect(log == [.removedEmptySplit("s")])
    }

    @Test func aSplitWithOneTabTurnsBackIntoThatTabInPlace() throws {
        let (after, log) = repaired(
            try splitGraph(panes: ["x"], split: SidebarSplit(widthFactors: [1], focusedItemID: "x")))
        #expect(after["s"] == nil)
        #expect(after["unpinned"]?.childrenIDs == ["before", "x", "after"])
        #expect(after["x"]?.parentID == "unpinned")
        #expect(log == [.dissolvedSingleTabSplit("s", tab: "x")])
    }

    @Test func aSplitDamagedIntoEmptyOrSingleByMissingTabsIsRepairedToo() throws {
        var graph = try splitGraph(panes: ["x", "y"])
        graph.items["x"] = nil
        let (single, _) = repaired(graph)
        #expect(single["unpinned"]?.childrenIDs == ["before", "y", "after"])

        graph.items["y"] = nil
        let (empty, log) = repaired(graph)
        #expect(empty["unpinned"]?.childrenIDs == ["before", "after"])
        #expect(log.contains(.removedEmptySplit("s")))
    }

    @Test func tabsBeyondTheFourthLeaveTheSplitAndNothingIsLost() throws {
        var graph = try splitGraph(panes: ["p1", "p2", "p3", "p4"])
        // Build a fifth and sixth pane by editing the raw graph, as a damaged file could.
        for extra in ["p5", "p6"] {
            graph.items[SidebarItemID(extra)] = .tab(id: SidebarItemID(extra), url: "https://\(extra).example.com")
            graph.items[SidebarItemID(extra)]?.parentID = "s"
            graph.items["s"]?.childrenIDs.append(SidebarItemID(extra))
        }
        let (after, log) = repaired(graph)
        #expect(after["s"]?.childrenIDs == ["p1", "p2", "p3", "p4"])
        #expect(after["unpinned"]?.childrenIDs == ["before", "s", "p5", "p6", "after"])
        #expect(log == [.movedExtraSplitPane("p5", from: "s"), .movedExtraSplitPane("p6", from: "s")])
    }

    @Test func widthFactorsAndFocusThatDoNotFitAreReset() throws {
        // Wrong count.
        var (after, log) = repaired(try splitGraph(panes: ["x", "y"], split: SidebarSplit(widthFactors: [1, 1, 1])))
        #expect(after.split("s")?.widthFactors == [] && log == [.fixedSplitLayout("s")])
        // Not positive.
        (after, log) = repaired(try splitGraph(panes: ["x", "y"], split: SidebarSplit(widthFactors: [1, -1])))
        #expect(after.split("s")?.widthFactors == [] && log == [.fixedSplitLayout("s")])
        // Not finite.
        (after, log) = repaired(try splitGraph(panes: ["x", "y"], split: SidebarSplit(widthFactors: [.nan, 1])))
        #expect(after.split("s")?.widthFactors == [])
        // Right count but not summing to 1: normalized, not reset.
        (after, log) = repaired(try splitGraph(panes: ["x", "y"], split: SidebarSplit(widthFactors: [3, 1])))
        #expect(approximately(after.split("s")?.widthFactors ?? [], [0.75, 0.25]) && log == [.fixedSplitLayout("s")])
        // Focus on something that is not a pane.
        (after, log) = repaired(try splitGraph(panes: ["x", "y"], split: SidebarSplit(focusedItemID: "after")))
        #expect(after.split("s")?.focusedItemID == nil && log == [.fixedSplitLayout("s")])
        #expect(after.focusedSplitPaneID("s") == "x")
    }

    @Test func aSplitInsideRecentlyRecoveredIsRepairedAfterItMoves() throws {
        var graph = try splitGraph(panes: ["x"])
        graph.items["s"]?.parentID = "gone"
        graph.items["unpinned"]?.childrenIDs.removeAll { $0 == "s" }
        let (after, log) = repaired(graph)
        #expect(after["s"] == nil)
        #expect(after[.recentlyRecovered]?.childrenIDs == ["x"])
        #expect(log.contains(.dissolvedSingleTabSplit("s", tab: "x")))
    }

    @Test func aSplitWithTwoToFourSoundTabsSurvivesRepairUntouched() throws {
        for count in 2...4 {
            let panes = (1...count).map { SidebarItemID("p\($0)") }
            let graph = try splitGraph(panes: panes)
            let (after, log) = repaired(graph)
            #expect(log.isEmpty && after == graph && after.splitPaneIDs("s") == panes)
        }
    }

    @Test func aNonTabChildLeavesTheSplitAndTheTabsAreWhatCount() throws {
        // The commit-time rule runs on its own, so it must agree with the integrity rule about what a pane is.
        // Two tabs and a folder: the split stays with its tabs, and the folder sits after it.
        var graph = try splitGraph(panes: ["x", "y"])
        graph.items["f"] = SidebarItem.folder(id: "f", title: "F")
        graph.items["f"]?.parentID = "s"
        graph.items["s"]?.childrenIDs.insert("f", at: 1)
        var log: [SidebarRepair] = []
        graph.repairSplits(&log)
        #expect(graph["s"]?.childrenIDs == ["x", "y"])
        #expect(graph["unpinned"]?.childrenIDs == ["before", "s", "f", "after"])
        #expect(graph["f"]?.parentID == "unpinned")
        #expect(log == [.movedExtraSplitPane("f", from: "s")])
        #expect(graph.integrityProblems().isEmpty)

        // One tab and a folder: the split turns back into the tab, the folder follows it.
        var single = try splitGraph(panes: ["x"])
        single.items["f"] = SidebarItem.folder(id: "f", title: "F")
        single.items["f"]?.parentID = "s"
        single.items["s"]?.childrenIDs.append("f")
        log = []
        single.repairSplits(&log)
        #expect(single["unpinned"]?.childrenIDs == ["before", "x", "f", "after"])
        #expect(log.contains(.dissolvedSingleTabSplit("s", tab: "x")))
        #expect(single.integrityProblems().isEmpty)
    }

    @Test func aPaneLeavingThroughAPlainChangeKeepsTheOthersProportions() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c", "d"], id: "s")
            try store.setSplitWidthFactors("s", [2, 1, 1])
            try store.apply([.delete("c")])
            #expect(store.graph.splitPaneIDs("s") == ["b", "d"])
            #expect(approximately(store.graph.splitWidthFractions("s"), [2.0 / 3, 1.0 / 3]))
            try store.apply([.delete("b")])
            #expect(store.graph["s"] == nil)
        }
    }

    @Test func theCommitReportsTheSplitsItRemovedOrDissolved() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.lastCommitRepairs.isEmpty)
            try store.createSplit(from: ["b", "c"], id: "s")
            #expect(store.lastCommitRepairs.isEmpty)
            try store.apply([.delete("c")])
            #expect(store.lastCommitRepairs == [.dissolvedSingleTabSplit("s", tab: "b")])
            try store.apply([.setActiveTab("a")])
            #expect(store.lastCommitRepairs.isEmpty)
        }
    }

    @Test func theStoreDissolvesASplitLeftWithOneTabWhenAPlainDeleteCommits() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.apply([.delete("c")])
            expectNoSmallSplit(store, remaining: "b", at: ["a", "b", "d", "e", "folder"])
            #expect(try store.repair().isEmpty)
        }
    }

    @Test func draggingAPaneOfATwoPaneSplitToFavoritesLeavesNoOneTabSplit() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.moveToFavorites("c")
            expectNoSmallSplit(store, remaining: "b", at: ["a", "b", "d", "e", "folder"])
            #expect(store.graph.isInFavorites("c"))
        }
    }

    @Test func movingAPaneToAnotherSpaceLeavesNoOneTabSplit() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.apply([.insertSpace("second", title: "Second")])
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.moveToSpace("c", space: "second")
            expectNoSmallSplit(store, remaining: "b", at: ["a", "b", "d", "e", "folder"])
            #expect(store.graph.spaceID(containing: "c") == "second")
        }
    }

    @Test func deletingAPaneThroughThePlainPathLeavesNoOneTabSplit() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c", "d"], id: "s")
            try store.apply([.delete("b")])
            #expect(store.graph.splitPaneIDs("s") == ["c", "d"])
            try store.apply([.delete("d")])
            expectNoSmallSplit(store, remaining: "c", at: ["a", "c", "e", "folder"])
        }
    }

    /// The saved graph and the file it reopens as hold the lone tab in the split's place and need no repair.
    private func expectNoSmallSplit(_ store: SidebarStore, remaining: SidebarItemID, at order: [SidebarItemID]) {
        #expect(store.graph["s"] == nil)
        #expect(unpinnedOrder(store) == order)
        #expect(store.graph.splitID(containing: remaining) == nil)
        #expect(store.graph.integrityProblems().isEmpty)
        let reopened = try? SidebarStore(fileURL: store.fileURL)
        #expect(reopened?.graph == store.graph)
        #expect(reopened?.openReport.repairs.isEmpty == true)
    }

    @Test func aPaneLeavingWithTheFocusDoesNotBlockLaterSplitChanges() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.apply([.insertSpace("second", title: "Second")])
            try store.createSplit(from: ["a", "b", "c", "d"], id: "s")
            try store.setFocusedPane("c")
            try store.moveToSpace("c", space: "second")
            #expect(store.graph.splitPaneIDs("s") == ["a", "b", "d"])
            #expect(store.graph.split("s")?.focusedItemID == nil)
            try store.setSplitWidthFactors("s", [2, 1, 1])
            try store.moveSplitDivider("s", dividerIndex: 0, to: 0.6)
            try store.movePane("d", to: 0)
            try store.addPane("e", to: "s")
            try store.removePane("e")
            #expect(store.graph.splitPaneIDs("s") == ["d", "a", "b"])
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func addingAPaneKeepsEveryPaneAtTheMinimum() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c"], id: "s")
            try store.setSplitWidthFactors("s", [0.1, 0.8, 0.1])
            try store.addPane("d", to: "s")
            let fractions = store.graph.splitWidthFractions("s")
            #expect(fractions.count == 4)
            #expect(fractions.allSatisfy { $0 >= SidebarSplit.minimumPaneFraction - 1e-9 })
            #expect(abs(sum(fractions) - 1) < 1e-9)
        }
    }

    @Test func anOrphanedEmptySplitIsRemovedWithoutAnEmptyRecoveredFolder() throws {
        var graph = try splitGraph(panes: [])
        graph.items["s"]?.parentID = nil
        graph.items["unpinned"]?.childrenIDs.removeAll { $0 == "s" }
        let (after, log) = repaired(graph)
        #expect(after["s"] == nil && after[.recentlyRecovered] == nil)
        #expect(log == [.removedEmptySplit("s")])
    }
}
