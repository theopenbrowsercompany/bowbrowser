import Foundation
import Testing

@testable import BowCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/ArcImport/\(name)", withExtension: "json"))
    return try Data(contentsOf: url)
}

private func tabs(_ nodes: [ArcImportNode]) -> [ArcImportTab] {
    nodes.compactMap { if case .tab(let tab) = $0 { tab } else { nil } }
}

private func folder(_ node: ArcImportNode) throws -> ArcImportFolder {
    guard case .folder(let folder) = node else { throw ArcImportTestError.wrongKind }
    return folder
}

enum ArcImportTestError: Error { case wrongKind }

@Suite struct ArcImportFixtureTests {
    @Test func summaryLineMatchesTheEndToEndLine() throws {
        let result = try ArcImporter.parse(fixture("sidebar-three-spaces"))
        #expect(result.report.summaryLine == "spaces=3 folders=5 depth=3 pinned=18")
    }

    @Test func mapsSpacesWithTitleIconThemeAndProfile() throws {
        let spaces = try ArcImporter.parse(fixture("sidebar-three-spaces")).spaces
        #expect(spaces.map(\.title) == ["Work", "Personal", "Scratch"])
        #expect(spaces[0].icon == .emoji("\u{1F4BC}"))
        #expect(spaces[0].theme == ArcImportTheme(style: "blendedGradient", appearance: "dark"))
        #expect(spaces[0].profile == .default)
        #expect(spaces[1].icon == .symbol("heart"))
        #expect(spaces[1].theme == nil)
        #expect(spaces[1].profile == .custom(directoryBasename: "Profile 1"))
        #expect(spaces[2].icon == .emoji("\u{1F9EA}"))
    }

    @Test func keepsNestedAndEmptyFoldersAndLoosePinsInOrder() throws {
        let work = try #require(try ArcImporter.parse(fixture("sidebar-three-spaces")).spaces.first)
        // Loose pins stay at the top level next to the folder, in sidebar order.
        #expect(work.pinned.count == 4)
        let dev = try folder(work.pinned[2])
        #expect(dev.name == "Dev")
        #expect(dev.icon == .symbol("bolt"))
        #expect(dev.children.count == 4)
        let docs = try folder(dev.children[2])
        let deep = try folder(docs.children[1])
        #expect(deep.name == "Deep")
        #expect(tabs(deep.children).map(\.url) == ["https://deep.example.com"])
        let empty = try folder(dev.children[3])
        #expect(empty.name == "Empty")
        #expect(empty.children.isEmpty)
    }

    @Test func keepsCustomPinnedNames() throws {
        let work = try #require(try ArcImporter.parse(fixture("sidebar-three-spaces")).spaces.first)
        let loose = tabs(work.pinned)
        #expect(loose[0].customName == "Mail")
        #expect(loose[0].savedTitle == "Inbox (3)")
        #expect(loose[1].customName == nil)
        let dev = try folder(work.pinned[2])
        #expect(tabs(dev.children)[1].customName == "Builds")
    }

    @Test func mapsSplitViewsAndUnpinnedTabs() throws {
        let work = try #require(try ArcImporter.parse(fixture("sidebar-three-spaces")).spaces.first)
        guard case .splitView(let split) = work.pinned[3] else { throw ArcImportTestError.wrongKind }
        #expect(split.panes.map(\.id) == ["t7", "t8"])
        #expect(split.orientation == .horizontal)
        #expect(split.widthFactors == [0.5, 0.5])
        #expect(split.focusedPane == 1)
        #expect(tabs(work.unpinned).map(\.url) == ["https://news.example.com"])
    }

    @Test func keepsFavoritesPerProfile() throws {
        let favorites = try ArcImporter.parse(fixture("sidebar-three-spaces")).favorites
        #expect(favorites.map(\.profile) == [.default, .custom(directoryBasename: "Profile 1")])
        #expect(tabs(favorites[0].items).map(\.savedTitle) == ["Chat", "Notes"])
        #expect(tabs(favorites[1].items).map(\.savedTitle) == ["Photos"])
    }

    @Test func reportsWhatItSkipsAndWhy() throws {
        let report = try ArcImporter.dryRun(fixture("sidebar-three-spaces"))
        let reasons = report.skipped.map(\.reason)
        #expect(reasons.filter { $0 == .liveFolder }.count == 1)
        #expect(reasons.filter { $0 == .easel }.count == 1)
        #expect(reasons.filter { $0 == .tabWithoutURL }.count == 1)
        // One empty split view in a Space and one in Favorites.
        #expect(reasons.filter { $0 == .emptySplitView }.count == 2)
        #expect(report.skipped.count == 5)
        #expect(report.skipped.first { $0.reason == .liveFolder }?.label == "Pull requests")
    }

    @Test func countsEverythingInTheReport() throws {
        let report = try ArcImporter.dryRun(fixture("sidebar-three-spaces"))
        #expect(report.spaces == 3)
        #expect(report.folders == 5)
        #expect(report.emptyFolders == 1)
        #expect(report.maxFolderDepth == 3)
        #expect(report.pinnedTabs == 18)
        #expect(report.unpinnedTabs == 1)
        #expect(report.favorites == 3)
        #expect(report.splitViews == 1)
        #expect(report.customNamedTabs == 3)
        #expect(report.recoveredItems == 0)
        #expect(report.text.contains("Spaces: 3"))
        #expect(report.text.contains("1 x Live Folders are not imported"))
    }

    @Test func dryRunMatchesParseAndIsRepeatable() throws {
        let data = try fixture("sidebar-three-spaces")
        let first = try ArcImporter.dryRun(data)
        #expect(first == (try ArcImporter.parse(data)).report)
        #expect(first == (try ArcImporter.dryRun(data)))
    }
}
