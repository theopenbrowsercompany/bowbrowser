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

    @Test func aNewPaneGoesIntoANewSplitOrTheActiveTabsSplit() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let side = NewPanePlacement.createWith("a", orientation: .horizontal, newPaneFirst: false)
            #expect(store.graph.newPanePlacement(besides: "a") == side)
            #expect(
                store.graph.newPanePlacement(besides: "in-folder")
                    == .createWith("in-folder", orientation: .horizontal, newPaneFirst: false))
            try store.createSplit(from: ["b", "c", "d"], id: "s")
            #expect(store.graph.newPanePlacement(besides: "c") == .addPane(to: "s", at: 3))
            try store.addPane("e", to: "s")
            #expect(store.graph.newPanePlacement(besides: "c") == nil)
        }
    }

    @Test func aNewPaneOpensBesideAPinnedTabAsArcAllows() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(
                store.graph.newPanePlacement(besides: "p")
                    == .createWith("p", orientation: .horizontal, newPaneFirst: false))
            try store.createSplit(from: ["p", "q"], id: "s")
            #expect(store.graph.newPanePlacement(besides: "q") == .addPane(to: "s", at: 2))
        }
    }

    @Test func topAndBottomSplitsAreStacked() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(
                store.graph.newPanePlacement(besides: "a", edge: .top)
                    == .createWith("a", orientation: .vertical, newPaneFirst: true))
            #expect(
                store.graph.newPanePlacement(besides: "a", edge: .bottom)
                    == .createWith("a", orientation: .vertical, newPaneFirst: false))
            try store.createSplit(from: ["b", "c"], orientation: .vertical, id: "v")
            #expect(store.graph.newPanePlacement(besides: "c", edge: .top) == .addPane(to: "v", at: 0))
            #expect(store.graph.newPanePlacement(besides: "c", edge: .bottom) == .addPane(to: "v", at: 2))
            // Add Split View extends a stacked split at its end too.
            #expect(store.graph.newPanePlacement(besides: "c", edge: .trailing) == .addPane(to: "v", at: 2))
            // A side by side split has one layout: no top or bottom pane joins it.
            try store.createSplit(from: ["d", "e"], id: "h")
            #expect(store.graph.newPanePlacement(besides: "d", edge: .top) == nil)
            #expect(store.graph.newPanePlacement(besides: "d", edge: .bottom) == nil)
            #expect(store.graph.newPanePlacement(besides: "d", edge: .trailing) == .addPane(to: "h", at: 2))
        }
    }

    @Test func aNewPaneIsRefusedBesideAFavoriteOrNothing() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            #expect(store.graph.newPanePlacement(besides: "fav") == nil)
            #expect(store.graph.newPanePlacement(besides: "fav", edge: .top) == nil)
            #expect(store.graph.newPanePlacement(besides: nil) == nil)
            #expect(store.graph.newPanePlacement(besides: "folder") == nil)
            #expect(store.graph.newPanePlacement(besides: "missing") == nil)
        }
    }

    // MARK: Opening a new tab as a pane

    @Test func aNewPaneBesideAPinnedTabMakesAPinnedSplitInItsPlace() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let space = store.graph.spaces[0]
            let split = try store.openNewPane("f", besides: "q", splitID: "s")
            #expect(split == "s")
            #expect(store.graph.children(of: space.pinnedContainerID).map(\.id) == ["p", "s"])
            #expect(store.graph.splitPaneIDs("s") == ["q", "f"])
            #expect(store.graph.isPinned("f"))
            #expect(store.graph.split("s")?.orientation == .horizontal)
            #expect(store.graph.focusedSplitPaneID("s") == "f")
            #expect(!store.graph.children(of: space.unpinnedContainerID).map(\.id).contains("f"))
        }
    }

    @Test func aNewPinnedPaneTakesTheFirstPageBrowsedToAsItsAddress() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let newTab = try #require(URL(string: "https://f.example.com"))
            let site = try #require(URL(string: "https://site.example.com/page"))
            try store.openNewPane("f", besides: "q", splitID: "s")
            #expect(store.graph["f"]?.tab?.savedURL == "")
            #expect(store.graph.pinnedURL(of: "f") == nil)
            #expect(!store.graph.hasNavigatedAwayFromPinnedURL("f", liveURL: newTab))
            // The new tab page it opens on is not an address the person picked; the first page after it is.
            #expect(!store.graph.recordsSettledPage("f", url: newTab, newTabURL: newTab))
            #expect(store.graph.recordsSettledPage("f", url: site, newTabURL: newTab))
            try store.apply([.setSavedPage("f", url: site.absoluteString, title: "Site")])
            #expect(store.graph.pinnedURL(of: "f") == site)
            // From then on browsing never changes it.
            let other = try #require(URL(string: "https://other.example.com"))
            #expect(!store.graph.recordsSettledPage("f", url: other, newTabURL: newTab))
            #expect(store.graph.hasNavigatedAwayFromPinnedURL("f", liveURL: other))
            // The pinned tab beside it kept its own address.
            #expect(store.graph["q"]?.tab?.savedURL == "https://q.example.com")
            #expect(!store.graph.recordsSettledPage("q", url: other, newTabURL: newTab))
        }
    }

    @Test func aNewPaneJoiningAPinnedSplitHasNoAddressYetAndATodayPaneKeepsRecording() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            let newTab = try #require(URL(string: "https://new.example.com"))
            let site = try #require(URL(string: "https://site.example.com"))
            try store.openNewPane("f", besides: "q", splitID: "s")
            try store.openNewPane("e", besides: "f", edge: .trailing)
            #expect(store.graph.splitPaneIDs("s") == ["q", "f", "e"])
            #expect(store.graph["e"]?.tab?.savedURL == "")
            #expect(store.graph.recordsSettledPage("e", url: site, newTabURL: newTab))
            // Beside a today tab the new pane keeps its address and records every page, as any today tab does.
            try store.openNewPane("d", besides: "a", splitID: "t")
            #expect(store.graph["d"]?.tab?.savedURL == "https://d.example.com")
            #expect(store.graph.recordsSettledPage("d", url: newTab, newTabURL: newTab))
            #expect(store.graph.recordsSettledPage("d", url: site, newTabURL: newTab))
            // A Favorite never records, and neither does an item that is not a tab.
            #expect(!store.graph.recordsSettledPage("fav", url: site, newTabURL: newTab))
            #expect(!store.graph.recordsSettledPage("folder", url: site, newTabURL: newTab))
        }
    }

    @Test func aNewPaneBesideAFolderTabMakesTheSplitInTheFolder() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.openNewPane("f", besides: "in-folder", edge: .top, splitID: "s")
            #expect(store.graph.children(of: "folder").map(\.id) == ["s"])
            #expect(store.graph.splitPaneIDs("s") == ["f", "in-folder"])
            #expect(store.graph.split("s")?.orientation == .vertical)
        }
    }

    @Test func aNewPaneJoinsTheActiveSplitAtItsEdgeWithAnEqualShare() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], orientation: .vertical, id: "s")
            try store.openNewPane("f", besides: "c", edge: .top)
            #expect(store.graph.splitPaneIDs("s") == ["f", "b", "c"])
            let fractions = store.graph.splitWidthFractions("s")
            #expect(fractions.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 })
            #expect(store.graph.focusedSplitPaneID("s") == "f")
        }
    }

    @Test func openingANewPaneIsRefusedWhereNoneFits() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], id: "s")
            let before = store.graph
            #expect(throws: SidebarStoreError.self) { try store.openNewPane("f", besides: "c", edge: .top) }
            #expect(throws: SidebarStoreError.self) { try store.openNewPane("f", besides: "fav") }
            #expect(throws: SidebarStoreError.self) { try store.openNewPane("a", besides: "a") }
            #expect(throws: SidebarStoreError.self) { try store.openNewPane("b", besides: "a") }
            #expect(throws: SidebarStoreError.self) { try store.openNewPane("fav", besides: "a") }
            #expect(store.graph == before)
        }
    }

    @Test func aStackedSplitShowsStacked() throws {
        try withTemporaryFolder { folder in
            let store = try makeStore(in: folder)
            try store.createSplit(from: ["b", "c"], orientation: .vertical, id: "s")
            #expect(store.graph.splitPanes(showing: "b")?.orientation == .vertical)
            try store.selectTab("b")
            var display = SplitViewDisplay()
            let plan = SplitPanes(
                splitID: "s", panes: ["b", "c"], focused: "b", fractions: [0.5, 0.5], orientation: .vertical)
            #expect(display.update(graph: store.graph, shownNow: ["b"]) == .show(plan))
            display.record(shown: ["b", "c"])
            #expect(display.update(graph: store.graph, shownNow: ["b", "c"]) == .none)
            // Turning the split shows it again in its new layout.
            try store.setSplitOrientation("s", .horizontal)
            var turned = plan
            turned.orientation = .horizontal
            #expect(display.update(graph: store.graph, shownNow: ["b", "c"]) == .show(turned))
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
