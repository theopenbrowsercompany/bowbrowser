import Foundation
import Testing

@testable import BowCore

extension SidebarItemData {
    fileprivate var isSplit: Bool {
        if case .split = self { return true }
        return false
    }
}

@Suite struct SidebarRepairTests {
    /// Every tab, folder and split in `before` still exists after repair: repair never deletes what the person made.
    /// The one exception is a split holding fewer than two tabs, which repair removes or turns back into its tab.
    private func expectNothingLost(_ before: SidebarGraph, _ after: SidebarGraph) {
        for item in before.items.values where !item.data.isContainer && !item.data.isSplit {
            #expect(after[item.id]?.data == item.data, "lost \(item.id)")
        }
    }

    private func repaired(_ graph: SidebarGraph) -> (SidebarGraph, [SidebarRepair]) {
        var copy = graph
        let log = copy.repair()
        #expect(copy.integrityProblems() == [])
        expectNothingLost(graph, copy)
        return (copy, log)
    }

    @Test func soundGraphIsLeftAlone() throws {
        let graph = try SidebarGraph.twelveItems()
        let (after, log) = repaired(graph)
        #expect(log.isEmpty)
        #expect(after == graph)
    }

    @Test func childPointingAtAParentThatDoesNotListItIsReattached() throws {
        var graph = try SidebarGraph.twelveItems()
        graph.items["work"]?.childrenIDs = ["deep"]
        let (after, log) = repaired(graph)
        #expect(after["work"]?.childrenIDs == ["deep", "docs"])
        #expect(log == [.reattachedChild("docs", parent: "work")])
    }

    @Test func wrongParentIDIsCorrectedFromTheParentThatListsIt() throws {
        var graph = try SidebarGraph.twelveItems()
        graph.items["docs"]?.parentID = "unpinned"
        let (after, log) = repaired(graph)
        #expect(after["docs"]?.parentID == "work")
        #expect(after["work"]?.childrenIDs == ["docs", "deep"])
        #expect(after["unpinned"]?.childrenIDs == ["news", "search"])
        #expect(log == [.fixedParentID("docs", parent: "work")])
    }

    @Test func listedByTwoParentsKeepsTheOneItsParentIDNames() throws {
        var graph = try SidebarGraph.twelveItems()
        graph.items["unpinned"]?.childrenIDs.append("docs")
        let (after, log) = repaired(graph)
        #expect(after["unpinned"]?.childrenIDs == ["news", "search"])
        #expect(after["work"]?.childrenIDs == ["docs", "deep"])
        #expect(log == [.droppedMisplacedChild(parent: "unpinned", child: "docs")])
    }

    @Test func missingAndDuplicateChildrenAreDropped() throws {
        var graph = try SidebarGraph.twelveItems()
        graph.items["unpinned"]?.childrenIDs = ["news", "ghost", "search", "news"]
        let (after, log) = repaired(graph)
        #expect(after["unpinned"]?.childrenIDs == ["news", "search"])
        #expect(
            Set(log) == [
                .droppedMissingChild(parent: "unpinned", child: "ghost"),
                .droppedDuplicateChild(parent: "unpinned", child: "news"),
            ])
    }

    @Test func orphansAreCollectedInRecentlyRecoveredInsteadOfDeleted() throws {
        var graph = try SidebarGraph.twelveItems()
        // "work" loses its parent entirely; "news" points at a parent that no longer exists.
        graph.items["work"]?.parentID = nil
        graph.items["pinned"]?.childrenIDs.removeAll { $0 == "work" }
        graph.items["news"]?.parentID = "deleted-folder"
        graph.items["unpinned"]?.childrenIDs.removeAll { $0 == "news" }
        let (after, log) = repaired(graph)

        let folder = try #require(after[.recentlyRecovered])
        #expect(folder.title == "Recently recovered")
        #expect(folder.parentID == "pinned")
        #expect(after["pinned"]?.childrenIDs.first == .recentlyRecovered)
        #expect(Set(folder.childrenIDs) == ["work", "news"])
        // A recovered folder keeps everything inside it.
        #expect(after["work"]?.childrenIDs == ["docs", "deep"])
        #expect(log.contains(.createdRecoveredFolder(.recentlyRecovered)))
        #expect(log.contains(.recovered("work")) && log.contains(.recovered("news")))

        // A second repair finds nothing to do.
        var again = after
        #expect(again.repair().isEmpty)
    }

    @Test func existingRecentlyRecoveredFolderIsReused() throws {
        var graph = try SidebarGraph.twelveItems().applying([
            .insert(.folder(id: .recentlyRecovered, title: "Recently recovered"), parent: "unpinned"),
            .insert(.tab(id: "old", url: "https://old.example"), parent: .recentlyRecovered),
        ])
        graph.items["unpinned"]?.childrenIDs.removeAll { $0 == "search" }
        graph.items["search"]?.parentID = nil
        let (after, _) = repaired(graph)
        #expect(after[.recentlyRecovered]?.parentID == "unpinned")
        #expect(after[.recentlyRecovered]?.childrenIDs == ["old", "search"])
    }

    @Test func orphanedRecentlyRecoveredFolderGetsAPlaceFirst() throws {
        var graph = try SidebarGraph.twelveItems().applying([
            .insert(.folder(id: .recentlyRecovered, title: "Recently recovered"), parent: "work")
        ])
        graph.items["work"]?.parentID = nil
        graph.items["pinned"]?.childrenIDs.removeAll { $0 == "work" }
        // The folder sits inside the orphan; it must not end up inside itself.
        let (after, _) = repaired(graph)
        #expect(after[.recentlyRecovered]?.parentID == "pinned")
        #expect(after["work"]?.parentID == .recentlyRecovered)
        #expect(after["work"]?.childrenIDs == ["docs", "deep"])
    }

    @Test func loopsAreOpenedAndRecovered() throws {
        var graph = try SidebarGraph.twelveItems()
        // "work" and "deep" point only at each other, cut off from every section.
        graph.items["pinned"]?.childrenIDs.removeAll { $0 == "work" }
        graph.items["work"]?.parentID = "deep"
        graph.items["deep"]?.childrenIDs.append("work")
        let (after, log) = repaired(graph)
        #expect(log.contains { if case .brokeCycle = $0 { return true } else { return false } })
        #expect(after.isDescendant("work", of: .recentlyRecovered))
        #expect(after.isDescendant("deep", of: .recentlyRecovered))
        #expect(after.isDescendant("docs", of: .recentlyRecovered))
    }

    @Test func itemsUnderParentsThatCannotHoldThemAreRecovered() throws {
        var graph = try SidebarGraph.twelveItems()
        // A folder inside a split, and a tab inside a tab.
        graph.items["deep"]?.parentID = "split"
        graph.items["work"]?.childrenIDs = ["docs"]
        graph.items["split"]?.childrenIDs.append("deep")
        graph.items["news"]?.parentID = "docs"
        graph.items["docs"]?.childrenIDs = ["news"]
        graph.items["unpinned"]?.childrenIDs = ["search"]
        let (after, _) = repaired(graph)
        #expect(after["split"]?.childrenIDs == ["left", "right"])
        #expect(after["docs"]?.childrenIDs == [])
        #expect(after[.recentlyRecovered]?.childrenIDs == ["news", "deep"])
    }

    @Test func missingSectionsAreRecreatedAndUnusedSectionsAreEmptiedIntoRecovered() throws {
        var graph = try SidebarGraph.twelveItems()
        // The space now points at a pinned section that does not exist, so the old one belongs to nobody.
        graph.spaces[0].pinnedContainerID = "lost-pinned"
        graph.items["favorites"] = nil
        let (after, log) = repaired(graph)
        #expect(after.firstSpace.pinnedContainerID != "lost-pinned")
        #expect(after["pinned"] == nil)
        #expect(log.contains(.removedUnusedContainer("pinned")))
        #expect(log.contains(.createdContainer(try #require(after.favoritesContainerIDs[.default]), kind: .favorites)))
        // The old pinned section's items are recovered in their old order, then Favorites' tabs, whose list is gone.
        #expect(after[.recentlyRecovered]?.parentID == after.firstSpace.pinnedContainerID)
        #expect(
            after[.recentlyRecovered]?.childrenIDs == ["work", "split", "renamed", "fav-cal", "fav-mail"])
    }

    @Test func sectionsSharedBetweenOwnersAreSplitAndDuplicateSpacesDropped() throws {
        var graph = try SidebarGraph.twelveItems()
        let copy = graph.spaces[0]
        graph.spaces.append(copy)
        graph.spaces.append(
            SidebarSpace(id: "other", title: "Other", pinnedContainerID: "pinned", unpinnedContainerID: "favorites"))
        let (after, log) = repaired(graph)
        #expect(after.spaces.map(\.id) == ["home", "other"])
        #expect(log.contains(.droppedDuplicateSpace("home")))
        #expect(after.spaces[1].pinnedContainerID != "pinned")
        #expect(after["pinned"]?.childrenIDs == ["work", "split", "renamed"])
    }

    @Test func noSpacesGetsADefaultSpace() {
        var graph = SidebarGraph.sample()
        graph.spaces = []
        let (after, log) = repaired(graph)
        #expect(after.spaces.count == 1)
        #expect(log.contains { if case .createdSpace = $0 { return true } else { return false } })
    }

    @Test func danglingActivePointersAreRepaired() throws {
        var graph = try SidebarGraph.twelveItems().applying([.insertSpace("second", title: "Second")])
        graph.activeSpaceID = "gone"
        graph.activeTabID = "work"
        let (after, log) = repaired(graph)
        #expect(after.activeSpaceID == "home")
        #expect(after.activeTabID == nil)
        #expect(log.contains(.resetActiveSpace("home")) && log.contains(.clearedActiveTab))

        // A missing active Space is filled in too, and recovered items go to that Space.
        graph = try SidebarGraph.twelveItems()
        graph.activeSpaceID = nil
        graph.items["news"]?.parentID = nil
        graph.items["unpinned"]?.childrenIDs = ["search"]
        let (filled, _) = repaired(graph)
        #expect(filled.activeSpaceID == "home")
        #expect(filled[.recentlyRecovered]?.parentID == "pinned")
    }

    @Test func itemsStoredUnderTheWrongKeyAreNormalized() throws {
        var graph = try SidebarGraph.twelveItems()
        let news = try #require(graph.items["news"])
        graph.items["news"] = nil
        graph.items["wrong-key"] = news
        let (after, _) = repaired(graph)
        #expect(after["news"]?.parentID == "unpinned")
        #expect(after["wrong-key"] == nil)
    }

    /// Scrambles the graph's links at random many times; every result must repair into a sound graph that keeps
    /// every item.
    @Test func randomDamageAlwaysRepairsWithoutLosingItems() throws {
        var random = SeededGenerator(seed: 42)
        let base = try SidebarGraph.twelveItems().applying([.insertSpace("second", title: "Second")])
        let ids = Array(base.items.keys).sorted() + ["ghost-1", "ghost-2"]
        for _ in 0..<500 {
            var graph = base
            for _ in 0..<Int.random(in: 1...6, using: &random) {
                let target = ids.randomElement(using: &random)!
                guard graph.items[target] != nil else { continue }
                switch Int.random(in: 0..<6, using: &random) {
                case 0: graph.items[target]?.parentID = ids.randomElement(using: &random)
                case 1: graph.items[target]?.parentID = nil
                case 2: graph.items[target]?.childrenIDs.append(ids.randomElement(using: &random)!)
                case 3: graph.items[target]?.childrenIDs.shuffle(using: &random)
                case 4: graph.items[target] = nil
                default: graph.items[target]?.childrenIDs.removeAll()
                }
            }
            var copy = graph
            copy.repair()
            #expect(copy.integrityProblems() == [])
            for (id, item) in graph.items where !item.data.isContainer && !item.data.isSplit {
                #expect(copy[id] != nil)
            }
        }
    }
}

/// A small deterministic random generator (SplitMix64) so the damage test is repeatable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
