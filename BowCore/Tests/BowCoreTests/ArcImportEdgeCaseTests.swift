import Foundation
import Testing

@testable import BowCore

/// Small hand written sidebar files, one behavior each.
private enum Sidebar {
    static func tab(_ id: String, parent: String?, url: String? = nil, title: String? = nil) -> String {
        let saved = url.map { "\"savedURL\": \"\($0)\"," } ?? ""
        return item(id, parent: parent, title: title, data: "{\"tab\": {\(saved) \"savedTitle\": \"Page \(id)\"}}")
    }

    static func folder(_ id: String, parent: String?, children: [String] = [], title: String = "Folder") -> String {
        item(id, parent: parent, title: title, data: "{\"list\": {}}", children: children)
    }

    static func container(_ id: String, children: [String]) -> String {
        let data = "{\"itemContainer\": {\"containerType\": \"topApps\"}}"
        return item(id, parent: nil, title: nil, data: data, children: children)
    }

    static func item(_ id: String, parent: String?, title: String?, data: String, children: [String] = []) -> String {
        let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
        let titleJSON = title.map { "\"\($0)\"" } ?? "null"
        let kids = children.map { "\"\($0)\"" }.joined(separator: ",")
        let body = "{\"id\": \"\(id)\", \"title\": \(titleJSON), \"parentID\": \(parentJSON), "
        return "\"\(id)\", " + body + "\"childrenIds\": [\(kids)], \"data\": \(data)}"
    }

    /// A one Space sidebar whose pinned root is `pin` and whose items are `items`.
    static func file(items: [String], containerKey: String = "\"global\": {}", extra: String = "") -> Data {
        let space = "\"s1\", {\"id\": \"s1\", \"title\": \"Home\", \"containerIDs\": [\"pinned\", \"pin\"]}"
        let json = """
            {"sidebar": {"containers": [{\(containerKey), "items": [\(items.joined(separator: ","))],
            "spaces": [\(space)]\(extra)}]}}
            """
        return Data(json.utf8)
    }

    static func raw(_ json: String) -> Data { Data(json.utf8) }
}

@Suite struct ArcImportMalformedInputTests {
    @Test func rejectsDataThatIsNotJSON() {
        #expect(throws: ArcImportError.invalidJSON) { try ArcImporter.parse(Data("not json".utf8)) }
        #expect(throws: ArcImportError.invalidJSON) { try ArcImporter.parse(Data()) }
    }

    @Test func rejectsJSONThatIsNotAnArcSidebar() {
        for text in ["{}", "[]", "{\"sidebar\": {}}", "{\"sidebar\": {\"containers\": 3}}"] {
            #expect(throws: ArcImportError.notAnArcSidebar) { try ArcImporter.parse(Sidebar.raw(text)) }
        }
    }

    @Test func emptyContainersImportNothing() throws {
        let result = try ArcImporter.parse(Sidebar.raw("{\"sidebar\": {\"containers\": []}}"))
        #expect(result.spaces.isEmpty)
        #expect(result.report.summaryLine == "spaces=0 folders=0 depth=0 pinned=0")
        #expect(result.report.skipped.isEmpty)
    }

    @Test func oddLengthArrayDropsTheDanglingElementAndSaysSo() throws {
        let pin = Sidebar.container("pin", children: ["a"])
        let a = Sidebar.tab("a", parent: "pin", url: "https://a.example.com")
        var data = String(decoding: Sidebar.file(items: [pin, a]), as: UTF8.self)
        data = data.replacingOccurrences(of: "\"items\": [", with: "\"items\": [\"stray\", ")
        // The stray key shifts every pair, so nothing decodes into a usable item.
        let result = try ArcImporter.parse(Data(data.utf8))
        #expect(result.report.skipped.contains { $0.reason == .malformedEntry })
        #expect(result.report.pinnedTabs == 0)
    }

    @Test func keyThatDoesNotMatchTheItemIdIsSkipped() throws {
        let pin = Sidebar.container("pin", children: ["a"])
        let a = Sidebar.tab("a", parent: "pin", url: "https://a.example.com")
            .replacingOccurrences(of: "\"id\": \"a\"", with: "\"id\": \"other\"")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, a]))
        #expect(result.report.skipped.map(\.reason).contains(.idMismatch))
        #expect(result.report.skipped.map(\.reason).contains(.missingItem))
        #expect(result.report.pinnedTabs == 0)
    }

    @Test func entriesOfTheWrongShapeAreSkippedWithoutStoppingTheRest() throws {
        let pin = Sidebar.container("pin", children: ["a"])
        let a = Sidebar.tab("a", parent: "pin", url: "https://a.example.com")
        let result = try ArcImporter.parse(
            Sidebar.file(items: [pin, a, "\"junk\", 42"], extra: ", \"topAppsContainerIDs\": \"oops\""))
        #expect(result.report.pinnedTabs == 1)
        #expect(result.report.skipped.filter { $0.reason == .malformedEntry }.count == 2)
    }

    @Test func tabsWithoutAnAddressAreSkipped() throws {
        let pin = Sidebar.container("pin", children: ["a", "b"])
        let a = Sidebar.tab("a", parent: "pin")
        let b = Sidebar.tab("b", parent: "pin", url: "   ")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, a, b]))
        #expect(result.report.skipped.map(\.reason) == [.tabWithoutURL, .tabWithoutURL])
        #expect(result.spaces[0].pinned.isEmpty)
    }

    @Test func spaceWithMissingContainersStillImportsEmpty() throws {
        let result = try ArcImporter.parse(Sidebar.file(items: []))
        #expect(result.spaces.count == 1)
        #expect(result.spaces[0].pinned.isEmpty)
        #expect(result.report.skipped.map(\.reason) == [.missingItem])
    }
}

@Suite struct ArcImportTolerantReadingTests {
    @Test func hugeNumbersInIconsDoNotCrash() throws {
        let space = """
            {"id": "s1", "title": "Home", "customInfo": {"iconType": {"emojiInt": 1e300}}, "containerIDs": []}
            """
        let text = "{\"sidebar\": {\"containers\": [{\"global\": {}, \"items\": [], \"spaces\": [\"s1\", \(space)]}]}}"
        let result = try ArcImporter.parse(Sidebar.raw(text))
        #expect(result.spaces.count == 1)
        #expect(result.spaces[0].icon == nil)
    }

    @Test func nonStringContainerIdsAreReported() throws {
        let space = "{\"id\": \"s1\", \"containerIDs\": [\"pinned\", 7]}"
        let text = "{\"sidebar\": {\"containers\": [{\"global\": {}, \"items\": [], \"spaces\": [\"s1\", \(space)]}]}}"
        let result = try ArcImporter.parse(Sidebar.raw(text))
        #expect(result.report.skipped.map(\.reason) == [.malformedEntry])
    }

    @Test func foldersInsideSplitViewsAreReportedNotDropped() throws {
        // A split whose other child was a folder is left with one tab, which imports as that plain tab.
        let pin = Sidebar.container("pin", children: ["sv"])
        let split = Sidebar.item("sv", parent: "pin", title: nil, data: "{\"splitView\": {}}", children: ["a", "f"])
        let a = Sidebar.tab("a", parent: "sv", url: "https://a.example.com")
        let f = Sidebar.folder("f", parent: "sv")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, split, a, f]))
        #expect(result.report.splitViews == 0)
        #expect(result.report.pinnedTabs == 1)
        #expect(result.report.skipped.map(\.reason) == [.unsupportedItem, .singleTabSplitView])
        guard case .tab(let tab) = try #require(result.spaces[0].pinned.first) else {
            Issue.record("expected a plain tab")
            return
        }
        #expect(tab.id == "a")
        #expect(result.spaces[0].pinned.count == 1)
    }

    @Test func aSplitViewWithTwoTabsAndAFolderKeepsItsTwoPanes() throws {
        let pin = Sidebar.container("pin", children: ["sv"])
        let split = Sidebar.item(
            "sv", parent: "pin", title: nil, data: "{\"splitView\": {}}", children: ["a", "b", "f"])
        let a = Sidebar.tab("a", parent: "sv", url: "https://a.example.com")
        let b = Sidebar.tab("b", parent: "sv", url: "https://b.example.com")
        let f = Sidebar.folder("f", parent: "sv")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, split, a, b, f]))
        #expect(result.report.splitViews == 1)
        #expect(result.report.skipped.map(\.reason) == [.unsupportedItem])
    }

    @Test func aSplitViewWithMoreThanFourTabsKeepsFourPanesAndTheRestFollowAsTabs() throws {
        let ids = ["a", "b", "c", "d", "e", "f"]
        let pin = Sidebar.container("pin", children: ["sv", "z"])
        let split = Sidebar.item(
            "sv", parent: "pin", title: nil,
            data: "{\"splitView\": {\"itemWidthFactors\": [1, 2, 3, 4, 5, 6], \"focusItemID\": \"e\"}}",
            children: ids)
        let tabs = ids.map { Sidebar.tab($0, parent: "sv", url: "https://\($0).example.com") }
        let after = Sidebar.tab("z", parent: "pin", url: "https://z.example.com")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, split] + tabs + [after]))
        let pinned = result.spaces[0].pinned
        guard case .splitView(let view) = pinned[0] else {
            Issue.record("expected a split first")
            return
        }
        #expect(view.panes.map(\.id) == ["a", "b", "c", "d"])
        #expect(view.widthFactors == [1, 2, 3, 4])
        #expect(view.focusedPane == nil)
        let rest = pinned.dropFirst().compactMap { node -> String? in
            if case .tab(let tab) = node { return tab.id }
            return nil
        }
        #expect(rest == ["e", "f", "z"])
        #expect(result.report.splitViews == 1)
        #expect(result.report.pinnedTabs == 7)
        #expect(result.report.skipped.map(\.reason) == [.extraSplitViewPanes])
    }
}

@Suite struct ArcImportContainerKindTests {
    @Test func skipsKindsItDoesNotImportAndSaysSo() throws {
        let kinds = ["incognito", "littleBrowser", "standalone", "mystery"]
        let containers = kinds.map { "{\"type\": \"\($0)\", \"items\": [], \"spaces\": []}" }
        let global = "{\"global\": {}, \"items\": [], \"spaces\": []}"
        let text = "{\"sidebar\": {\"containers\": [\(global), \(containers.joined(separator: ","))]}}"
        let result = try ArcImporter.parse(Sidebar.raw(text))
        let skipped = result.report.skipped
        #expect(skipped.count == 4)
        #expect(skipped.allSatisfy { $0.reason == .unsupportedContainer })
        #expect(skipped.compactMap(\.label) == kinds)
    }

    @Test func kindCanBeAKeyOrATypeValueAndBookkeepingContainersAreIgnored() throws {
        let pin = Sidebar.container("pin", children: ["a"])
        let a = Sidebar.tab("a", parent: "pin", url: "https://a.example.com")
        for key in ["\"global\": {}", "\"type\": \"global\""] {
            let result = try ArcImporter.parse(Sidebar.file(items: [pin, a], containerKey: key))
            #expect(result.report.pinnedTabs == 1)
        }
        let text = "{\"sidebar\": {\"containers\": [{\"version\": 1}]}}"
        #expect(try ArcImporter.parse(Sidebar.raw(text)).report.skipped.isEmpty)
    }

    @Test func skipsItemKindsItDoesNotImport() throws {
        let pin = Sidebar.container("pin", children: ["n", "e", "x", "z"])
        let note = Sidebar.item("n", parent: "pin", title: "Note", data: "{\"arcDocument\": {}}")
        let easel = Sidebar.item("e", parent: "pin", title: "Easel", data: "{\"easel\": {}}")
        let shared = Sidebar.item("x", parent: "pin", title: "Shared", data: "{\"sharedObject\": {}}")
        let strange = Sidebar.item("z", parent: "pin", title: "Strange", data: "{\"futureKind\": {}}")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, note, easel, shared, strange]))
        #expect(result.report.skipped.map(\.reason) == [.note, .easel, .sharedObject, .unsupportedItem])
        #expect(result.spaces[0].pinned.isEmpty)
    }
}

@Suite struct ArcImportTreeWalkTests {
    @Test func itemsThatOnlyPointAtTheirParentAreAttachedAfterTheListedOnes() throws {
        let pin = Sidebar.container("pin", children: ["a"])
        let a = Sidebar.tab("a", parent: "pin", url: "https://a.example.com")
        let b = Sidebar.tab("b", parent: "pin", url: "https://b.example.com")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, b, a]))
        #expect(result.spaces[0].pinned.compactMap { if case .tab(let t) = $0 { t.id } else { nil } } == ["a", "b"])
        #expect(result.report.skipped.isEmpty)
    }

    @Test func parentPointerWinsWhenTwoFoldersListTheSameItem() throws {
        let pin = Sidebar.container("pin", children: ["f1", "f2"])
        let f1 = Sidebar.folder("f1", parent: "pin", children: ["a"])
        let f2 = Sidebar.folder("f2", parent: "pin", children: ["a"])
        let a = Sidebar.tab("a", parent: "f2", url: "https://a.example.com")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, f1, f2, a]))
        let pinned = result.spaces[0].pinned
        guard case .folder(let first) = pinned[0], case .folder(let second) = pinned[1] else {
            throw ArcImportTestError.wrongKind
        }
        #expect(first.children.isEmpty)
        #expect(second.children.count == 1)
        #expect(result.report.skipped.isEmpty)
    }

    @Test func missingChildrenAreReported() throws {
        let pin = Sidebar.container("pin", children: ["ghost"])
        let result = try ArcImporter.parse(Sidebar.file(items: [pin]))
        #expect(result.report.skipped == [ArcImportSkipped(reason: .missingItem, itemID: "ghost", label: nil)])
    }

    @Test func anItemListedTwiceAppearsOnce() throws {
        let pin = Sidebar.container("pin", children: ["a", "a"])
        let a = Sidebar.tab("a", parent: "pin", url: "https://a.example.com")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, a]))
        #expect(result.report.pinnedTabs == 1)
        #expect(result.report.skipped.map(\.reason) == [.duplicateReference])
    }

    @Test func folderCyclesTerminate() throws {
        let pin = Sidebar.container("pin", children: ["f1"])
        let f1 = Sidebar.folder("f1", parent: "pin", children: ["f2"])
        let f2 = Sidebar.folder("f2", parent: "f1", children: ["f1"])
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, f1, f2]))
        #expect(result.report.folders == 2)
        #expect(result.report.maxFolderDepth == 2)
    }

    @Test func absurdNestingIsCutOff() throws {
        var items = [Sidebar.container("pin", children: ["d0"])]
        for depth in 0..<80 {
            let parent = depth == 0 ? "pin" : "d\(depth - 1)"
            items.append(Sidebar.folder("d\(depth)", parent: parent, children: ["d\(depth + 1)"]))
        }
        let result = try ArcImporter.parse(Sidebar.file(items: items))
        #expect(result.report.maxFolderDepth == 64)
        #expect(result.report.skipped.map(\.reason) == [.nestedTooDeep])
    }

    @Test func legacyAddressFieldsAndFavoritesContainerAreRead() throws {
        let pin = Sidebar.container("pin", children: [])
        let top = Sidebar.container("top", children: ["a"])
        let a = Sidebar.item(
            "a", parent: "top", title: nil,
            data: "{\"tab\": {\"url\": \"https://old.example.com\", \"title_legacy\": \"Old\"}}")
        let result = try ArcImporter.parse(
            Sidebar.file(items: [pin, top, a], extra: ", \"topAppsContainerID\": \"top\""))
        #expect(result.favorites.count == 1)
        #expect(result.favorites[0].profile == .default)
        guard case .tab(let tab) = result.favorites[0].items[0] else { throw ArcImportTestError.wrongKind }
        #expect(tab.url == "https://old.example.com")
        #expect(tab.savedTitle == "Old")
    }
}

@Suite struct ArcImportOrphanTests {
    private func orphanFile() -> Data {
        let pin = Sidebar.container("pin", children: ["a"])
        let a = Sidebar.tab("a", parent: "pin", url: "https://a.example.com")
        let lost = Sidebar.folder("lost", parent: "gone", children: ["inner"], title: "Lost")
        let inner = Sidebar.tab("inner", parent: "lost", url: "https://inner.example.com")
        let loose = Sidebar.tab("loose", parent: nil, url: "https://loose.example.com")
        return Sidebar.file(items: [pin, a, lost, inner, loose])
    }

    @Test func collectKeepsOrphansWithTheirSubtrees() throws {
        let result = try ArcImporter.parse(orphanFile())
        #expect(result.recovered.count == 2)
        guard case .folder(let lost) = result.recovered[0] else { throw ArcImportTestError.wrongKind }
        #expect(lost.name == "Lost")
        #expect(lost.children.count == 1)
        #expect(result.report.recoveredItems == 2)
        #expect(result.report.recoveredTabs == 2)
        // Recovered items do not inflate the pinned count.
        #expect(result.report.pinnedTabs == 1)
        #expect(result.report.skipped.isEmpty)
    }

    @Test func dropLeavesOrphansOutAndReportsThem() throws {
        let result = try ArcImporter.parse(orphanFile(), options: ArcImportOptions(orphans: .drop))
        #expect(result.recovered.isEmpty)
        #expect(result.report.recoveredItems == 0)
        #expect(result.report.skipped.map(\.reason) == [.orphan, .orphan])
        #expect(result.report.skipped.map(\.label) == ["Lost", nil])
    }

    @Test func itemsInContainersNoSpaceUsesAreReportedAsUnreachable() throws {
        let pin = Sidebar.container("pin", children: [])
        let other = Sidebar.container("other-machine", children: ["a"])
        let a = Sidebar.tab("a", parent: "other-machine", url: "https://a.example.com")
        let result = try ArcImporter.parse(Sidebar.file(items: [pin, other, a]))
        #expect(result.report.skipped.map(\.reason) == [.unreachable])
        #expect(result.recovered.isEmpty)
    }
}
