import Foundation
import Testing

@testable import BowCore

@Suite struct ArcImportChoicesTests {
    @Test func aNewChoiceTicksEverySpaceAndKeepsFavoritesButNotUnpinnedTabs() throws {
        let result = try parsed("sidebar-three-spaces")
        let choices = ArcImportChoices(for: result)
        #expect(choices.checkedSpaceIDs == Set(result.spaces.map(\.id)))
        #expect(choices.plan.mode == .arcSpaces)
        #expect(choices.plan.includeFavorites)
        #expect(!choices.plan.includeUnpinnedTabs)
    }

    @Test func untickingASpaceLeavesItOutOfThePreview() throws {
        let result = try parsed("sidebar-three-spaces")
        var choices = ArcImportChoices(for: result)
        let dropped = try #require(result.spaces.last)
        choices.checkedSpaceIDs.remove(dropped.id)
        let preview = choices.preview(of: result, in: nil)
        #expect(preview.spaces.count == result.spaces.count - 1)
        #expect(preview.omissions.contains { $0.reason == .spaceNotSelected && $0.label == dropped.title })
        choices.checkedSpaceIDs = []
        #expect(choices.preview(of: result, in: nil).isEmpty)
    }

    @Test func rowsListSpacesFoldersTabsAndFavoritesWithNesting() throws {
        let result = try parsed("sidebar-client-project-phase")
        let rows = ArcImportChoices(for: result).preview(of: result, in: nil).rows
        let clients = try #require(rows.firstIndex { $0.kind == .space && $0.title == "Clients" })
        #expect(
            rows[clients + 1...clients + 5].map { "\($0.depth):\($0.title)" }
                == ["1:client", "2:project", "3:phase", "4:A", "4:Kanban"])
        #expect(rows.contains { $0.kind == .folder && $0.depth == 1 && $0.title == "archive" })
        let favorites = try #require(rows.firstIndex { $0.kind == .favorites })
        #expect(rows[favorites...].filter { $0.kind == .tab }.count == 4)
    }

    @Test func unpinnedTabsShowUnderOneLineOnlyWhenIncluded() throws {
        let result = try parsed("sidebar-client-project-phase")
        var choices = ArcImportChoices(for: result)
        #expect(!choices.preview(of: result, in: nil).rows.contains { $0.kind == .section })
        choices.includeUnpinnedTabs = true
        let rows = choices.preview(of: result, in: nil).rows
        let section = try #require(rows.firstIndex { $0.kind == .section })
        #expect(rows[section + 1].title == "Today" && rows[section + 1].depth == 2)
    }

    @Test func rowsMatchTheSidebarAfterApplying() throws {
        try withStore { store, _ in
            let result = try parsed("sidebar-client-project-phase")
            let preview = ArcImportChoices(for: result).preview(of: result, in: store.graph)
            let applied = try ArcImporter.apply(preview, to: store)
            let trees = applied.importedPinnedTrees(in: store.graph)
            let applyRows = ArcImportPreview(
                mode: preview.mode,
                spaces: zip(preview.spaces, trees).map { entry, tree in
                    var entry = entry
                    entry.pinned = tree
                    return entry
                }, favorites: [], omissions: [], skippedByImporter: []
            ).rows
            let previewRows = ArcImportPreview(
                mode: preview.mode, spaces: preview.spaces, favorites: [], omissions: [], skippedByImporter: []
            ).rows
            #expect(applyRows == previewRows)
        }
    }

    @Test func skippingSpacesTurnsTheCheckboxesOff() throws {
        var choices = ArcImportChoices(for: try parsed("sidebar-three-spaces"))
        #expect(choices.choosesSpaces)
        choices.mode = .skipSpaces
        #expect(!choices.choosesSpaces)
    }
}
