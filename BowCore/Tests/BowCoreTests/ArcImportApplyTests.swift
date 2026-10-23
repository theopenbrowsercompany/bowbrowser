import Foundation
import Testing

@testable import BowCore

private func parsed(_ name: String) throws -> ArcImportResult {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/ArcImport/\(name)", withExtension: "json"))
    return try ArcImporter.parse(Data(contentsOf: url))
}

/// Runs `body` with a sidebar store that has only its starter Space, saved in a temporary folder.
private func withStore(_ body: (SidebarStore, URL) throws -> Void) throws {
    try withTemporaryFolder { folder in
        let url = folder.appendingPathComponent(SidebarStore.fileName)
        try body(try SidebarStore(fileURL: url), url)
    }
}

private func titles(_ nodes: [ArcImportPreviewNode]) -> [String] { nodes.map(\.title) }

private func space(titled title: String, in graph: SidebarGraph) throws -> SidebarSpace {
    try #require(graph.spaces.first { $0.title == title })
}

private func favoriteTitles(_ profile: SidebarProfileID, in graph: SidebarGraph) -> [String] {
    graph.favoriteIDs(for: profile).compactMap { graph.items[$0]?.tab?.savedTitle }
}

@Suite struct ArcImportPreviewTests {
    @Test func summaryLineMatchesTheEndToEndLine() throws {
        let preview = ArcImporter.preview(try parsed("sidebar-client-project-phase"))
        #expect(preview.summaryLine == "tree=client/project/phase/[A] favorites=4")
    }

    @Test func previewKeepsNestingEmptyFoldersCustomNamesAndFavorites() throws {
        let preview = ArcImporter.preview(try parsed("sidebar-client-project-phase"))
        let clients = try #require(preview.spaces.first)
        #expect(titles(clients.pinned) == ["client", "Loose", "archive"])
        let phase = clients.pinned[0].children[0].children[0]
        #expect(phase.title == "phase")
        #expect(titles(phase.children) == ["A", "Kanban"])
        #expect(phase.children[1].customName == "Kanban")
        #expect(phase.children[1].savedTitle == "Board")
        #expect(clients.pinned[2].isEmptyFolder)
        let counts = preview.counts
        #expect(counts.folders == 4)
        #expect(counts.emptyFolders == 1)
        #expect(counts.maxFolderDepth == 3)
        #expect(counts.customNamedTabs == 1)
        #expect(counts.favorites == 4)
        #expect(preview.text.contains("Favorites: 4"))
    }

    @Test func previewChangesNothingAndRepeats() throws {
        let result = try parsed("sidebar-three-spaces")
        try withStore { store, url in
            let before = store.graph
            let unsaved = store.hasUnsavedChanges
            let first = ArcImporter.preview(result)
            let second = ArcImporter.preview(result)
            #expect(first == second)
            #expect(store.graph == before)
            #expect(store.hasUnsavedChanges == unsaved)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func unpinnedTabsComeOnlyWhenAsked() throws {
        let result = try parsed("sidebar-client-project-phase")
        let without = ArcImporter.preview(result)
        #expect(without.spaces[0].unpinned.isEmpty)
        #expect(without.omissions.contains { $0.reason == .unpinnedTabsNotIncluded && $0.label == "Clients" })
        let with = ArcImporter.preview(result, plan: ArcImportPlan(includeUnpinnedTabs: true))
        #expect(titles(with.spaces[0].unpinned) == ["Today"])
        #expect(with.omissions.isEmpty)
    }

    @Test func recoveredItemsGoInOneFolderInTheFirstSpace() throws {
        var result = try parsed("sidebar-client-project-phase")
        result.recovered = [.tab(ArcImportTab(id: "r1", url: "https://lost.example.com", savedTitle: "Lost"))]
        let kept = ArcImporter.preview(result)
        #expect(kept.spaces[0].pinned.last?.title == "Recovered from Arc")
        #expect(titles(kept.spaces[0].pinned.last?.children ?? []) == ["Lost"])
        #expect(kept.spaces[1].pinned.allSatisfy { $0.title != "Recovered from Arc" })
        let dropped = ArcImporter.preview(result, plan: ArcImportPlan(includeRecoveredItems: false))
        #expect(dropped.omissions.contains { $0.reason == .recoveredItemsNotIncluded })
        let noSpaces = ArcImporter.preview(result, plan: ArcImportPlan(mode: .skipSpaces))
        #expect(noSpaces.omissions.contains { $0.reason == .recoveredItemsWithoutSpace })
    }

    @Test func parserSkipsStayInThePreview() throws {
        let result = try parsed("sidebar-three-spaces")
        let preview = ArcImporter.preview(result)
        #expect(preview.skippedByImporter == result.report.skipped)
        #expect(preview.skippedByImporter.contains { $0.reason == .liveFolder })
        #expect(preview.skippedByImporter.contains { $0.reason == .easel })
    }
}

@Suite struct ArcImportModeTests {
    @Test func arcSpacesModeMakesSpacesInTheProfilesTheyHad() throws {
        let preview = ArcImporter.preview(try parsed("sidebar-three-spaces"), plan: ArcImportPlan(mode: .arcSpaces))
        #expect(preview.spaces.map(\.title) == ["Work", "Personal", "Scratch"])
        #expect(
            preview.spaces.map(\.profile)
                == [.defaultProfile, .arcProfile(SidebarProfileID("arc-Profile 1")), .defaultProfile])
        #expect(preview.favorites.map(\.profile) == [.defaultProfile, .arcProfile(SidebarProfileID("arc-Profile 1"))])
        #expect(preview.favorites.map { titles($0.items) } == [["Chat", "Notes"], ["Photos"]])
    }

    @Test func spacesAsProfilesGivesEverySpaceItsOwnProfileAndFavoritesCopy() throws {
        try withStore { store, _ in
            let result = try parsed("sidebar-three-spaces")
            let applied = try ArcImporter.apply(result, plan: ArcImportPlan(mode: .spacesAsProfiles), to: store)
            let imported = applied.spaceIDs.compactMap { store.graph.space($0) }
            #expect(imported.map(\.title) == ["Work", "Personal", "Scratch"])
            let profiles = imported.map(\.profileID)
            #expect(Set(profiles).count == 3)
            #expect(!profiles.contains(.default))
            #expect(favoriteTitles(profiles[0], in: store.graph) == ["Chat", "Notes"])
            #expect(favoriteTitles(profiles[1], in: store.graph) == ["Photos"])
            #expect(favoriteTitles(profiles[2], in: store.graph) == ["Chat", "Notes"])
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func spacesAsProfilesGetsNewProfilesOnEveryImport() throws {
        try withStore { store, _ in
            let result = try parsed("sidebar-client-project-phase")
            let first = try ArcImporter.apply(result, plan: ArcImportPlan(mode: .spacesAsProfiles), to: store)
            let second = try ArcImporter.apply(result, plan: ArcImportPlan(mode: .spacesAsProfiles), to: store)
            let profiles = (first.spaceIDs + second.spaceIDs).compactMap { store.graph.space($0)?.profileID }
            #expect(profiles.count == 4)
            #expect(Set(profiles).count == 4)
        }
    }

    @Test func skipSpacesBringsOnlyDefaultProfileFavorites() throws {
        try withStore { store, _ in
            let before = store.graph.spaces
            let result = try parsed("sidebar-three-spaces")
            let preview = ArcImporter.preview(result, plan: ArcImportPlan(mode: .skipSpaces))
            #expect(preview.spaces.isEmpty)
            #expect(preview.counts.favorites == 2)
            #expect(
                preview.omissions.filter { $0.reason == .spacesSkipped }.map(\.label) == [
                    "Work", "Personal", "Scratch",
                ])
            #expect(preview.omissions.contains { $0.reason == .favoritesWithoutSpace })
            let applied = try ArcImporter.apply(preview, to: store)
            #expect(store.graph.spaces == before)
            #expect(applied.spaceIDs.isEmpty)
            #expect(favoriteTitles(.default, in: store.graph) == ["Chat", "Notes"])
            #expect(store.graph.favoritesContainerIDs.keys.count == 1)
        }
    }

    @Test func spaceSelectionPicksWhichSpacesComeAndTheirFavorites() throws {
        let result = try parsed("sidebar-three-spaces")
        let plan = ArcImportPlan(mode: .arcSpaces, selectedSpaceIDs: ["space-work", "space-scratch"])
        let preview = ArcImporter.preview(result, plan: plan)
        #expect(preview.spaces.map(\.title) == ["Work", "Scratch"])
        #expect(preview.omissions.contains { $0.reason == .spaceNotSelected && $0.label == "Personal" })
        // Profile 1 has no Space left, so its Favorites have nowhere to show.
        #expect(preview.omissions.contains { $0.reason == .favoritesWithoutSpace && $0.label.contains("Profile 1") })
        #expect(preview.favorites.map(\.profile) == [.defaultProfile])
        #expect(preview.summaryLine.hasSuffix("favorites=2"))
    }

    @Test func nothingSelectedImportsNothing() throws {
        try withStore { store, url in
            let result = try parsed("sidebar-three-spaces")
            let plan = ArcImportPlan(mode: .arcSpaces, selectedSpaceIDs: [], includeFavorites: false)
            let preview = ArcImporter.preview(result, plan: plan)
            #expect(preview.isEmpty)
            let before = store.graph
            let applied = try ArcImporter.apply(preview, to: store)
            #expect(applied.isEmpty)
            #expect(store.graph == before)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func favoritesCanBeLeftOut() throws {
        let preview = ArcImporter.preview(
            try parsed("sidebar-three-spaces"), plan: ArcImportPlan(includeFavorites: false))
        #expect(preview.favorites.isEmpty)
        #expect(preview.omissions.filter { $0.reason == .favoritesNotIncluded }.count == 2)
    }
}

@Suite struct ArcImportApplyTests {
    @Test func appliedClientProjectPhaseTreeAndFavoritesMatchTheEndToEndLine() throws {
        try withStore { store, _ in
            let result = try parsed("sidebar-client-project-phase")
            let applied = try ArcImporter.apply(result, plan: ArcImportPlan(), to: store)
            #expect(applied.summaryLine(in: store.graph) == "tree=client/project/phase/[A] favorites=4")
            #expect(favoriteTitles(.default, in: store.graph) == ["Mail", "Calendar", "Chat", "Docs"])
        }
    }

    @Test func whatLandsIsWhatThePreviewShowed() throws {
        try withStore { store, _ in
            let result = try parsed("sidebar-three-spaces")
            let plan = ArcImportPlan(mode: .arcSpaces, includeUnpinnedTabs: true)
            let preview = ArcImporter.preview(result, plan: plan)
            let applied = try ArcImporter.apply(preview, to: store)
            #expect(
                applied.importedPinnedTrees(in: store.graph).map { $0.map(\.withoutIcons) }
                    == preview.spaces.map { $0.pinned.map(\.withoutIcons) })
            #expect(
                applied.importedUnpinnedTrees(in: store.graph).map { $0.map(\.withoutIcons) }
                    == preview.spaces.map { $0.unpinned.map(\.withoutIcons) })
            #expect(applied.itemCount == store.graph.contentItemCount)
            #expect(applied.summaryLine(in: store.graph) == preview.summaryLine)
            #expect(store.graph.integrityProblems().isEmpty)
        }
    }

    @Test func keepsNestingEmptyFoldersCustomNamesSplitsAndOrderInTheStore() throws {
        try withStore { store, _ in
            try ArcImporter.apply(try parsed("sidebar-three-spaces"), plan: ArcImportPlan(), to: store)
            let graph = store.graph
            let work = try space(titled: "Work", in: graph)
            let pinned = graph.children(of: work.pinnedContainerID)
            #expect(pinned.map { $0.title ?? $0.tab?.savedTitle ?? "" } == ["Mail", "Calendar", "Dev", ""])
            #expect(pinned[0].title == "Mail")
            #expect(pinned[0].tab?.savedTitle == "Inbox (3)")
            #expect(pinned[1].title == nil)
            let dev = graph.children(of: pinned[2].id)
            #expect(dev.map { $0.title ?? "" } == ["", "Builds", "Docs", "Empty"])
            let docs = graph.children(of: dev[2].id)
            #expect(docs[1].title == "Deep")
            #expect(graph.children(of: docs[1].id).map { $0.tab?.savedURL } == ["https://deep.example.com"])
            #expect(graph.children(of: dev[3].id).isEmpty)
            guard case .split(let split) = pinned[3].data else { throw ArcImportTestError.wrongKind }
            #expect(split.orientation == .horizontal)
            #expect(graph.children(of: pinned[3].id).count == 2)
            // Loose pins stay at the top level, in Arc's order, and the Space order is Arc's too.
            #expect(graph.spaces.suffix(3).map(\.title) == ["Work", "Personal", "Scratch"])
        }
    }

    @Test func importedSpacesGoAfterTheOnesThatWereThereAndNothingIsActivated() throws {
        try withStore { store, _ in
            let before = store.graph
            try ArcImporter.apply(try parsed("sidebar-client-project-phase"), plan: ArcImportPlan(), to: store)
            #expect(store.graph.spaces.first == before.spaces.first)
            #expect(store.graph.spaces.count == before.spaces.count + 2)
            #expect(store.graph.activeSpaceID == before.activeSpaceID)
            #expect(store.graph.activeTabID == before.activeTabID)
        }
    }

    @Test func applySavesOnceAndALaterOpenSeesTheImport() throws {
        try withStore { store, url in
            try ArcImporter.apply(try parsed("sidebar-client-project-phase"), plan: ArcImportPlan(), to: store)
            #expect(!store.hasUnsavedChanges)
            let reopened = try SidebarStore(fileURL: url)
            #expect(reopened.graph == store.graph)
        }
    }

    @Test func aFailureHalfwayChangesNothing() throws {
        try withStore { store, url in
            let before = store.graph
            var preview = ArcImporter.preview(try parsed("sidebar-client-project-phase"))
            // A Favorites copy with no Space to belong to fails after the Spaces were already inserted.
            preview.favorites.append(.init(profile: .separateProfile, forArcSpaceID: "missing", items: []))
            #expect(throws: SidebarStoreError.self) { try ArcImporter.apply(preview, to: store) }
            #expect(store.graph == before)
            #expect(!store.isInTransaction)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func applyIsRefusedInsideAnOpenTransaction() throws {
        try withStore { store, _ in
            try store.beginTransaction()
            #expect(throws: SidebarStoreError.nestedTransaction) {
                try ArcImporter.apply(try parsed("sidebar-client-project-phase"), plan: ArcImportPlan(), to: store)
            }
            store.rollbackTransaction()
        }
    }
}

@Suite struct ArcImportUndoTests {
    @Test func undoRestoresTheSidebarInOneStep() throws {
        try withStore { store, url in
            let defaultFavorite = try store.addFavorite(url: "https://keep.example.com", title: "Keep")
            let before = store.graph
            let plan = ArcImportPlan(mode: .arcSpaces, selectedSpaceIDs: ["space-work", "space-scratch"])
            let applied = try ArcImporter.apply(try parsed("sidebar-three-spaces"), plan: plan, to: store)
            #expect(store.graph != before)
            #expect(store.graph.favoriteIDs(for: .default).first == defaultFavorite)
            try applied.undo(on: store)
            #expect(store.graph == before)
            #expect(!store.hasUnsavedChanges)
            #expect(try SidebarStore(fileURL: url).graph == before)
        }
    }

    @Test func undoWithNewProfilesLeavesOnlyAnEmptyFavoritesSection() throws {
        try withStore { store, _ in
            let before = store.graph
            let applied = try ArcImporter.apply(
                try parsed("sidebar-three-spaces"), plan: ArcImportPlan(mode: .arcSpaces), to: store)
            try applied.undo(on: store)
            let graph = store.graph
            #expect(graph.spaces == before.spaces)
            #expect(graph.activeSpaceID == before.activeSpaceID)
            #expect(graph.activeTabID == before.activeTabID)
            #expect(graph.contentItemCount == before.contentItemCount)
            #expect(graph.items.count == before.items.count + 1)
            let extra = try #require(graph.favoritesContainerIDs[SidebarProfileID("arc-Profile 1")])
            #expect(graph.children(of: extra).isEmpty)
            #expect(graph.integrityProblems().isEmpty)
        }
    }

    @Test func undoSkipsWhatIsAlreadyGoneAndKeepsLaterWork() throws {
        try withStore { store, _ in
            let applied = try ArcImporter.apply(
                try parsed("sidebar-client-project-phase"), plan: ArcImportPlan(), to: store)
            let removedFavorite = try #require(applied.favoriteItemIDs.first)
            try store.deleteFavorite(removedFavorite)
            let later = try store.addFavorite(url: "https://later.example.com", title: "Later")
            try applied.undo(on: store)
            #expect(store.graph.favoriteIDs(for: .default) == [later])
            #expect(store.graph.spaces.count == 1)
        }
    }

    @Test func undoOfAnEmptyImportDoesNothing() throws {
        try withStore { store, url in
            let applied = try ArcImporter.apply(
                try parsed("sidebar-three-spaces"), plan: ArcImportPlan(selectedSpaceIDs: []), to: store)
            try applied.undo(on: store)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}
