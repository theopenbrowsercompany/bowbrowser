import Foundation
import Testing

@testable import BowCore

// Undo must never lose or corrupt what the person had before the import or did after it. Every test here starts from
// a sidebar the person built: nested folders, three Spaces, a selected tab that is not the first one, and Favorites.

/// Makes writes fail while `isFailing` is true, like a full disk.
private final class FlakyDisk: @unchecked Sendable {
    struct WriteFailure: Error {}
    var isFailing = false
    var writer: AtomicFileWriter {
        AtomicFileWriter { [self] _ in if isFailing { throw WriteFailure() } }
    }
}

/// The two Spaces of the fixture that live in Arc's default profile, so no new Favorites section is made.
private let defaultProfileSpaces = ArcImportPlan(mode: .arcSpaces, selectedSpaceIDs: ["space-work", "space-scratch"])

private struct Seeded {
    let store: SidebarStore
    let url: URL
    let home: SidebarSpaceID
    let play: SidebarSpaceID
    let study: SidebarSpaceID
}

/// A sidebar with Home (nested folders, a split, unpinned tabs, "News" selected), Play, Study and two Favorites.
private func withSeededStore(disk: FlakyDisk = FlakyDisk(), _ body: (Seeded) throws -> Void) throws {
    try withTemporaryFolder { folder in
        let url = folder.appendingPathComponent(SidebarStore.fileName)
        let store = try SidebarStore(fileURL: url, migrations: SidebarFileFormat.migrations, writer: disk.writer)
        let home = try #require(store.graph.activeSpaceID)
        let homeSpace = try #require(store.graph.space(home))
        let play = try store.createSpace(title: "Play", activate: false)
        let study = try store.createSpace(title: "Study", activate: false)
        let playSpace = try #require(store.graph.space(play))
        try store.apply([
            .insert(.folder(id: "work", title: "Work"), parent: homeSpace.pinnedContainerID),
            .insert(.tab(id: "docs", url: "https://docs.example.com", title: "Docs"), parent: "work"),
            .insert(.folder(id: "deep", title: "Deep"), parent: "work"),
            .insert(.tab(id: "deep-tab", url: "https://deep.example.com", title: "Deep"), parent: "deep"),
            .insert(.split(id: "split"), parent: homeSpace.pinnedContainerID),
            .insert(.tab(id: "left", url: "https://left.example.com", title: "Left"), parent: "split"),
            .insert(.tab(id: "right", url: "https://right.example.com", title: "Right"), parent: "split"),
            .insert(
                .tab(id: "mail-pin", url: "https://mail.example.com", title: "Mail"),
                parent: homeSpace.pinnedContainerID),
            .insert(
                .tab(id: "news", url: "https://news.example.com", title: "News"), parent: homeSpace.unpinnedContainerID),
            .insert(
                .tab(id: "search", url: "https://search.example.com", title: "Search"),
                parent: homeSpace.unpinnedContainerID),
            .insert(
                .tab(id: "play-pin", url: "https://play.example.com", title: "Play"),
                parent: playSpace.pinnedContainerID),
            .setActiveTab("news"),
        ])
        try store.addFavorite(url: "https://keep.example.com", title: "Keep")
        try store.addFavorite(url: "https://keep2.example.com", title: "Keep 2")
        try body(Seeded(store: store, url: url, home: home, play: play, study: study))
    }
}

private func applyImport(_ seeded: Seeded, plan: ArcImportPlan = defaultProfileSpaces) throws -> ArcImportApplied {
    try ArcImporter.apply(try parsed("sidebar-three-spaces"), plan: plan, to: seeded.store)
}

private func children(_ id: SidebarItemID, in graph: SidebarGraph) -> [SidebarItemID] {
    graph.children(of: id).map(\.id)
}

@Suite struct ArcImportUndoSafetyTests {
    @Test func seededSidebarComesBackExactlyIncludingTheFile() throws {
        try withSeededStore { seeded in
            let before = seeded.store.graph
            #expect(before.activeTabID == "news")
            let applied = try applyImport(seeded)
            #expect(seeded.store.graph != before)
            let undone = try applied.undo(on: seeded.store)
            #expect(seeded.store.graph == before)
            #expect(undone.saveFailure == nil)
            #expect(undone.keptItemIDs.isEmpty)
            #expect(Set(undone.removedItemIDs) == Set(applied.spaceItemIDs + applied.favoriteItemIDs))
            #expect(!seeded.store.hasUnsavedChanges)
            #expect(try SidebarStore(fileURL: seeded.url).graph == before)
        }
    }

    @Test func anExistingItemMovedIntoAnImportedSpaceSurvivesUndo() throws {
        try withSeededStore { seeded in
            let applied = try applyImport(seeded)
            let imported = try #require(seeded.store.graph.space(applied.spaceIDs[0]))
            // The person drags their nested "Work" folder into the imported Space's pinned section and their
            // "Search" tab into its unpinned one.
            try seeded.store.moveToSpace("work", space: imported.id, section: .pinned, index: 0)
            try seeded.store.moveToSpace("search", space: imported.id, section: .unpinned, index: 0)

            let undone = try applied.undo(on: seeded.store)

            let graph = seeded.store.graph
            let home = try #require(graph.space(seeded.home))
            #expect(undone.destinationSpaceID == seeded.home)
            #expect(Set(undone.keptItemIDs) == ["work", "search"])
            // They keep their section, go to the end of it, and bring everything inside them.
            #expect(children(home.pinnedContainerID, in: graph).last == "work")
            #expect(children(home.unpinnedContainerID, in: graph).last == "search")
            #expect(children("work", in: graph) == ["docs", "deep"])
            #expect(children("deep", in: graph) == ["deep-tab"])
            // Everything the import added is gone, and nothing else is.
            for id in applied.spaceItemIDs + applied.favoriteItemIDs { #expect(graph.items[id] == nil) }
            #expect(graph.spaces.map(\.id) == [seeded.home, seeded.play, seeded.study])
            #expect(graph.activeTabID == "news")
            #expect(graph.integrityProblems().isEmpty)
        }
    }

    @Test func tabsOpenedInAnImportedSpaceSurviveUndoInTheirOrder() throws {
        try withSeededStore { seeded in
            let applied = try applyImport(seeded)
            let graph = seeded.store.graph
            let imported = try #require(graph.space(applied.spaceIDs[0]))
            let importedFolder = try #require(
                graph.children(of: imported.pinnedContainerID).first { $0.title == "Dev" })
            try seeded.store.apply([
                .insert(
                    .tab(id: "opened-pinned", url: "https://a.example.com"), parent: imported.pinnedContainerID,
                    index: 0),
                .insert(.tab(id: "opened-in-folder", url: "https://b.example.com"), parent: importedFolder.id),
                .insert(.tab(id: "opened-today", url: "https://c.example.com"), parent: imported.unpinnedContainerID),
            ])

            let undone = try applied.undo(on: seeded.store)

            let after = seeded.store.graph
            let home = try #require(after.space(seeded.home))
            #expect(undone.keptItemIDs == ["opened-pinned", "opened-in-folder", "opened-today"])
            #expect(children(home.pinnedContainerID, in: after).suffix(2) == ["opened-pinned", "opened-in-folder"])
            #expect(children(home.unpinnedContainerID, in: after).last == "opened-today")
            #expect(after.integrityProblems().isEmpty)
        }
    }

    @Test func undoWithAnImportedSpaceOnScreenKeepsTheTabOpenedThere() throws {
        try withSeededStore { seeded in
            let applied = try applyImport(seeded)
            let imported = try #require(seeded.store.graph.space(applied.spaceIDs[0]))
            try seeded.store.switchToSpace(imported.id)
            try seeded.store.apply([
                .insert(.tab(id: "opened", url: "https://a.example.com"), parent: imported.unpinnedContainerID),
                .setActiveTab("opened"),
            ])

            try applied.undo(on: seeded.store)

            let graph = seeded.store.graph
            #expect(graph.items["opened"] != nil)
            #expect(graph.spaceID(containing: "opened") == seeded.home)
            // The person lands in the Space that took over their tab, and the tab is still the selected one.
            #expect(graph.activeSpaceID == seeded.home)
            #expect(graph.activeTabID == "opened")
            #expect(graph.integrityProblems().isEmpty)
        }
    }

    @Test func anImportedFavoriteMovedToAnExistingSpaceStays() throws {
        try withSeededStore { seeded in
            let applied = try applyImport(seeded)
            let moved = try #require(applied.favoriteItemIDs.first)
            try seeded.store.removeFavorite(moved, to: .pinned, in: seeded.play, at: 0)
            let keepers = seeded.store.graph.favoriteIDs(for: .default).prefix(2)

            try applied.undo(on: seeded.store)

            let graph = seeded.store.graph
            let play = try #require(graph.space(seeded.play))
            #expect(children(play.pinnedContainerID, in: graph).first == moved)
            #expect(graph.items[moved]?.tab?.savedTitle == "Chat")
            #expect(graph.favoriteIDs(for: .default).count == 2)
            #expect(Array(graph.favoriteIDs(for: .default)) == Array(keepers))
            for id in applied.favoriteItemIDs.dropFirst() { #expect(graph.items[id] == nil) }
        }
    }

    @Test func anImportedFavoriteDraggedIntoAnImportedSpaceIsKept() throws {
        try withSeededStore { seeded in
            let applied = try applyImport(seeded)
            let moved = try #require(applied.favoriteItemIDs.first)
            let imported = try #require(seeded.store.graph.space(applied.spaceIDs[0]))
            try seeded.store.removeFavorite(moved, to: .unpinned, in: imported.id, at: 0)

            let undone = try applied.undo(on: seeded.store)

            let graph = seeded.store.graph
            #expect(undone.keptItemIDs == [moved])
            #expect(graph.spaceID(containing: moved) == seeded.home)
            #expect(graph.integrityProblems().isEmpty)
        }
    }

    @Test func importedItemsThePersonMovedOutOfAnImportedSpaceStayPut() throws {
        try withSeededStore { seeded in
            let applied = try applyImport(seeded)
            let imported = try #require(seeded.store.graph.space(applied.spaceIDs[0]))
            let firstPin = try #require(seeded.store.graph.children(of: imported.pinnedContainerID).first)
            try seeded.store.moveToSpace(firstPin.id, space: seeded.study, section: .pinned)

            try applied.undo(on: seeded.store)

            let graph = seeded.store.graph
            #expect(graph.spaceID(containing: firstPin.id) == seeded.study)
        }
    }

    @Test func aSaveFailureDuringApplyKeepsTheImportAndIsReported() throws {
        let disk = FlakyDisk()
        try withSeededStore(disk: disk) { seeded in
            let before = seeded.store.graph
            disk.isFailing = true
            let applied = try applyImport(seeded)
            #expect(applied.saveFailure != nil)
            #expect(seeded.store.graph.spaces.count == before.spaces.count + 2)
            #expect(seeded.store.hasUnsavedChanges)
            // The store keeps the change and writes it once the disk works again.
            disk.isFailing = false
            try seeded.store.save()
            #expect(try SidebarStore(fileURL: seeded.url).graph == seeded.store.graph)
        }
    }

    @Test func aSaveFailureDuringUndoIsReportedAndTheUndoStillHappened() throws {
        let disk = FlakyDisk()
        try withSeededStore(disk: disk) { seeded in
            let before = seeded.store.graph
            let applied = try applyImport(seeded)
            #expect(applied.saveFailure == nil)
            disk.isFailing = true

            let undone = try applied.undo(on: seeded.store)

            #expect(undone.saveFailure != nil)
            #expect(seeded.store.graph == before)
            #expect(seeded.store.hasUnsavedChanges)
            disk.isFailing = false
            try seeded.store.save()
            #expect(try SidebarStore(fileURL: seeded.url).graph == before)
        }
    }

    @Test func undoIsRefusedWhenOnlyImportedSpacesRemain() throws {
        try withStore { store, _ in
            let starter = try #require(store.graph.activeSpaceID)
            let applied = try ArcImporter.apply(
                try parsed("sidebar-three-spaces"), plan: defaultProfileSpaces, to: store)
            try store.deleteSpace(starter)
            let before = store.graph
            #expect(throws: ArcImportUndoError.noOtherSpaceRemains) { try applied.undo(on: store) }
            #expect(store.graph == before)
            #expect(!store.isInTransaction)
            #expect(ArcImportUndoError.noOtherSpaceRemains.description.contains("only Spaces left"))
        }
    }

    @Test func undoTwiceDoesNothingTheSecondTime() throws {
        try withSeededStore { seeded in
            let before = seeded.store.graph
            let applied = try applyImport(seeded)
            try applied.undo(on: seeded.store)
            let second = try applied.undo(on: seeded.store)
            #expect(second == ArcImportUndone())
            #expect(seeded.store.graph == before)
        }
    }
}

@Suite struct ArcImportProfileIDTests {
    private func id(_ basename: String) -> String {
        guard case .arcProfile(let profile) = ArcImportProfileTarget.mapping(.custom(directoryBasename: basename))
        else {
            Issue.record("not an Arc profile target")
            return ""
        }
        return profile.rawValue
    }

    /// The characters the engine accepts in a profile ID (`IsValidProfileID` in `BowEngine.mm`).
    private func isEngineValid(_ profileID: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !profileID.isEmpty && profileID != "." && profileID != ".."
            && profileID.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    @Test func arcProfileFolderNamesBecomeIDsTheEngineAccepts() {
        for name in ["Profile 1", "Work/Home", "../x", "Café", "日本語", "", "a b  c", String(repeating: "x", count: 300)]
        {
            #expect(isEngineValid(id(name)), "\(name)")
        }
        #expect(id("Profile 1").hasPrefix("arc-profile-1-"))
    }

    @Test func namesThatDifferOnlyInCaseOrPunctuationGetDistinctIDsEvenIgnoringCase() {
        let names = ["Profile 1", "profile 1", "PROFILE 1", "Profile-1", "Profile_1", "Profile  1", "Profile 1 "]
        let ids = names.map(id)
        #expect(Set(ids.map { $0.lowercased() }).count == names.count)
    }

    @Test func theSameNameAlwaysGetsTheSameID() {
        #expect(id("Profile 1") == id("Profile 1"))
        // Café typed with a combining accent is the same folder name on disk as the single character form.
        #expect(id("Cafe\u{301}") == id("Caf\u{e9}"))
        // Pinned, so a change to the scheme (which would orphan every earlier import's Favorites) is deliberate.
        #expect(id("Profile 1") == "arc-profile-1-ef0ccd1ac1")
    }

    @Test func importedSpacesOfOneProfileShareOneValidID() throws {
        let preview = ArcImporter.preview(try parsed("sidebar-three-spaces"))
        let profiles = preview.spaces.map(\.profile).compactMap { target -> String? in
            if case .arcProfile(let profile) = target { return profile.rawValue }
            return nil
        }
        #expect(profiles == [id("Profile 1")])
        #expect(profiles.allSatisfy(isEngineValid))
    }
}
