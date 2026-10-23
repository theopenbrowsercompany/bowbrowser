import Foundation
import Testing

@testable import BowCore

@Suite struct SplitViewDisplayTests {
    /// Today holds tabs a to f and a folder with tab in-folder; pinned holds p and q; a Favorite fav. Tab "a" is
    /// selected.
    private func makeStore(in folder: URL) throws -> SidebarStore {
        let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
        let space = store.graph.spaces[0]
        var mutations: [SidebarMutation] = ["a", "b", "c", "d", "e", "f"].map {
            .insert(
                .tab(id: SidebarItemID($0), url: "https://\($0).example.com", title: $0),
                parent: space.unpinnedContainerID)
        }
        mutations += [
            .insert(.folder(id: "folder", title: "Folder"), parent: space.unpinnedContainerID),
            .insert(.tab(id: "in-folder", url: "https://in-folder.example.com"), parent: "folder"),
            .insert(.tab(id: "p", url: "https://p.example.com"), parent: space.pinnedContainerID),
            .insert(.tab(id: "q", url: "https://q.example.com"), parent: space.pinnedContainerID),
            .insert(
                .tab(id: "fav", url: "https://fav.example.com"),
                parent: try #require(store.graph.favoritesContainerID(for: .default))),
            .setActiveTab("a"),
        ]
        try store.apply(mutations)
        return store
    }

    // MARK: Selecting a pane focuses it

    @Test func selectingAPaneMakesItTheSplitsFocusedPaneAndKeepsTheWidths() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.setSplitWidthFactors("s", [3, 1])
            #expect(store.graph.focusedSplitPaneID("s") == "b")
            try store.selectTab("c")
            #expect(store.graph.split("s")?.focusedItemID == "c")
            #expect(store.graph.splitWidthFractions("s") == [0.75, 0.25])
            // Selecting a tab outside the split keeps the split's focus where it was.
            try store.selectTab("a")
            #expect(store.graph.split("s")?.focusedItemID == "c")
        }
    }

    // MARK: Panes to show

    @Test func theSplitOfTheActiveTabShowsWithThatTabFocused() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c", "d"], id: "s")
            try store.setSplitWidthFactors("s", [2, 1, 1])
            #expect(store.graph.splitPanes(showing: "a") == nil)
            #expect(store.graph.splitPanes(showing: nil) == nil)
            let panes = try #require(store.graph.splitPanes(showing: "c"))
            #expect(panes.splitID == "s")
            #expect(panes.panes == ["b", "c", "d"])
            #expect(panes.focused == "c")
            #expect(panes.fractions == [0.5, 0.25, 0.25])
        }
    }

    // MARK: Open in Split View

    @Test func openingATabBesideAPlainTabMakesASplitOfTheTwo() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.splitOpening("c", besides: "a") == .create(["a", "c"]))
            // A tab in a folder of the same section counts as the same section.
            #expect(store.graph.splitOpening("in-folder", besides: "a") == .create(["a", "in-folder"]))
            #expect(store.graph.splitOpening("q", besides: "p") == .create(["p", "q"]))
        }
    }

    @Test func openingATabBesideAPaneAddsItToThatSplitUntilItIsFull() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["a", "b", "c"], id: "s")
            #expect(store.graph.splitOpening("d", besides: "a") == .addPane("d", to: "s"))
            try store.addPane("d", to: "s")
            #expect(store.graph.splitOpening("e", besides: "a") == nil)
        }
    }

    @Test func openingInASplitIsRefusedWhereNoSplitCanBeMade() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["d", "e"], id: "s")
            let graph = store.graph
            #expect(graph.splitOpening("a", besides: "a") == nil)
            #expect(graph.splitOpening("a", besides: nil) == nil)
            #expect(graph.splitOpening("d", besides: "a") == nil)
            #expect(graph.splitOpening("fav", besides: "a") == nil)
            #expect(graph.splitOpening("a", besides: "fav") == nil)
            #expect(graph.splitOpening("p", besides: "a") == nil)
            #expect(graph.splitOpening("folder", besides: "a") == nil)
            #expect(graph.splitOpening("a", besides: "folder") == nil)
            #expect(graph.splitOpening("a", besides: "missing") == nil)
        }
    }

    // MARK: Add Split View (a new tab as a pane)

    @Test func aNewPaneGoesIntoANewSplitOrTheActiveTabsSplitInToday() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.newPanePlacement(besides: "a") == .createWith("a"))
            #expect(store.graph.newPanePlacement(besides: "in-folder") == .createWith("in-folder"))
            try store.createSplit(from: ["b", "c", "d"], id: "s")
            #expect(store.graph.newPanePlacement(besides: "c") == .addPane(to: "s"))
            try store.addPane("e", to: "s")
            #expect(store.graph.newPanePlacement(besides: "c") == nil)
        }
    }

    @Test func aNewPaneIsRefusedBesideAPinnedTabAFavoriteOrNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.newPanePlacement(besides: "p") == nil)
            #expect(store.graph.newPanePlacement(besides: "fav") == nil)
            #expect(store.graph.newPanePlacement(besides: nil) == nil)
            #expect(store.graph.newPanePlacement(besides: "folder") == nil)
        }
    }

    // MARK: Keeping the panes in step

    @Test func selectingAPaneShowsTheSplitAndALaterSelectionInsideItChangesNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            var display = SplitViewDisplay()
            #expect(display.update(graph: store.graph, shownNow: ["a"]) == .none)
            try store.selectTab("c")
            let plan = SplitPanes(splitID: "s", panes: ["b", "c"], focused: "c", fractions: [0.5, 0.5])
            #expect(display.update(graph: store.graph, shownNow: ["c"]) == .show(plan))
            display.record(shown: ["b", "c"])
            try store.selectTab("b")
            #expect(display.update(graph: store.graph, shownNow: ["b", "c"]) == .none)
            #expect(display.splitID == "s")
        }
    }

    @Test func aPaneThatLeftTheScreenIsNotLoadedAgainUntilItIsSelected() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["p", "q"], id: "s")
            try store.selectTab("p")
            var display = SplitViewDisplay()
            _ = display.update(graph: store.graph, shownNow: ["p"])
            display.record(shown: ["p", "q"])
            // Pinned q closed: it unloads and stays in the split, and the window shows p alone.
            #expect(display.update(graph: store.graph, shownNow: ["p"]) == .none)
            try store.selectTab("q")
            let plan = SplitPanes(splitID: "s", panes: ["p", "q"], focused: "q", fractions: [0.5, 0.5])
            #expect(display.update(graph: store.graph, shownNow: ["q"]) == .show(plan))
        }
    }

    @Test func aPaneTakenOutOfALargerSplitLeavesTheScreen() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c", "d"], id: "s")
            try store.selectTab("b")
            var display = SplitViewDisplay()
            _ = display.update(graph: store.graph, shownNow: ["b"])
            display.record(shown: ["b", "c", "d"])
            try store.removePane("c")
            let plan = SplitPanes(splitID: "s", panes: ["b", "d"], focused: "b", fractions: [0.5, 0.5])
            #expect(display.update(graph: store.graph, shownNow: ["b", "c", "d"]) == .show(plan))
        }
    }

    @Test func separatingOrDissolvingTheShownSplitShowsTheActiveTabAlone() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.selectTab("c")
            var display = SplitViewDisplay()
            _ = display.update(graph: store.graph, shownNow: ["c"])
            display.record(shown: ["b", "c"])
            try store.separateSplit("s")
            #expect(display.update(graph: store.graph, shownNow: ["b", "c"]) == .single("c"))
            display.record(shown: ["c"])
            #expect(display.splitID == nil)
            #expect(display.update(graph: store.graph, shownNow: ["c"]) == .none)
        }
    }

    @Test func panesNoSplitPutThereAreLeftAlone() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            var display = SplitViewDisplay()
            #expect(display.update(graph: store.graph, shownNow: ["a", "b"]) == .none)
            #expect(display.update(graph: store.graph, shownNow: ["a", "b", "c"]) == .none)
        }
    }

    @Test func switchingAwayAndBackShowsTheSplitAgainWithItsFocus() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.selectTab("c")
            var display = SplitViewDisplay()
            _ = display.update(graph: store.graph, shownNow: ["c"])
            display.record(shown: ["b", "c"])
            try store.selectTab("a")
            #expect(display.update(graph: store.graph, shownNow: ["a"]) == .none)
            #expect(display.splitID == nil)
            // The split row selects its focused pane.
            let focused = try #require(store.graph.focusedSplitPaneID("s"))
            #expect(focused == "c")
            try store.selectTab(focused)
            let plan = SplitPanes(splitID: "s", panes: ["b", "c"], focused: "c", fractions: [0.5, 0.5])
            #expect(display.update(graph: store.graph, shownNow: ["c"]) == .show(plan))
        }
    }

    @Test func noActiveTabShowsNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            try store.selectTab("b")
            var display = SplitViewDisplay()
            _ = display.update(graph: store.graph, shownNow: ["b"])
            try store.apply([.setActiveTab(nil)])
            #expect(display.update(graph: store.graph, shownNow: []) == .none)
            #expect(display.splitID == nil)
        }
    }
}
