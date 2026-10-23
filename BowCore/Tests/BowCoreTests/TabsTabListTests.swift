import Foundation
import Testing

@testable import BowCore

@Suite struct TabsTabListTests {
    private func makeTab(_ name: String) -> BrowserTab {
        BrowserTab(url: URL(string: "https://\(name).example"), title: name)
    }

    /// A list of tabs a, b, c, ... with the first one active.
    private func makeList(_ names: [String]) -> (TabList, [BrowserTabID]) {
        var list = TabList()
        let ids = names.map { list.open(makeTab($0), at: .end, activate: false)! }
        return (list, ids)
    }

    private func titles(_ list: TabList) -> [String] { list.tabs.map(\.title) }

    @Test func startsEmpty() {
        let list = TabList()
        #expect(list.isEmpty)
        #expect(list.activeID == nil)
        #expect(list.activeTab == nil)
    }

    @Test func firstTabBecomesActiveEvenInBackground() {
        var list = TabList()
        let id = list.open(makeTab("a"), activate: false)
        #expect(list.activeID == id)
    }

    @Test func openAfterActiveInsertsNextToActiveAndActivates() {
        var (list, ids) = makeList(["a", "b", "c"])
        list.select(ids[0])
        let id = list.open(makeTab("x"), at: .afterActive)
        #expect(titles(list) == ["a", "x", "b", "c"])
        #expect(list.activeID == id)
    }

    @Test func openAtEndAppendsAndActivates() {
        var (list, ids) = makeList(["a", "b"])
        list.select(ids[0])
        let id = list.open(makeTab("x"), at: .end)
        #expect(titles(list) == ["a", "b", "x"])
        #expect(list.activeID == id)
    }

    @Test func openInBackgroundKeepsActiveTab() {
        var (list, ids) = makeList(["a", "b"])
        list.select(ids[1])
        list.open(makeTab("x"), activate: false)
        #expect(titles(list) == ["a", "b", "x"])
        #expect(list.activeID == ids[1])
    }

    @Test func openRejectsDuplicateID() {
        var (list, ids) = makeList(["a"])
        let duplicate = BrowserTab(id: ids[0], title: "b")
        #expect(list.open(duplicate) == nil)
        #expect(titles(list) == ["a"])
    }

    @Test func selectChangesActiveTab() {
        var (list, ids) = makeList(["a", "b", "c"])
        let ok1 = list.select(ids[2])
        #expect(ok1)
        #expect(list.activeID == ids[2])
        #expect(list.activeIndex == 2)
    }

    @Test func selectUnknownIDChangesNothing() {
        var (list, ids) = makeList(["a", "b"])
        let ok2 = list.select(BrowserTabID())
        #expect(!ok2)
        #expect(list.activeID == ids[0])
    }

    @Test func closeInactiveTabKeepsActiveTab() {
        var (list, ids) = makeList(["a", "b", "c"])
        list.select(ids[2])
        let ok3 = list.close(ids[0])
        #expect(ok3)
        #expect(titles(list) == ["b", "c"])
        #expect(list.activeID == ids[2])
    }

    @Test func closeActiveTabSelectsTheNextOne() {
        var (list, ids) = makeList(["a", "b", "c"])
        list.select(ids[1])
        list.close(ids[1])
        #expect(titles(list) == ["a", "c"])
        #expect(list.activeID == ids[2])
    }

    @Test func closeActiveFirstTabSelectsTheNextOne() {
        var (list, ids) = makeList(["a", "b"])
        list.close(ids[0])
        #expect(list.activeID == ids[1])
    }

    @Test func closeActiveLastTabSelectsThePreviousOne() {
        var (list, ids) = makeList(["a", "b", "c"])
        list.select(ids[2])
        list.close(ids[2])
        #expect(list.activeID == ids[1])
    }

    @Test func closeLastTabLeavesEmptyList() {
        var (list, ids) = makeList(["a"])
        let ok4 = list.close(ids[0])
        #expect(ok4)
        #expect(list.isEmpty)
        #expect(list.activeID == nil)
    }

    @Test func closeUnknownIDChangesNothing() {
        var (list, _) = makeList(["a", "b"])
        let ok5 = list.close(BrowserTabID())
        #expect(!ok5)
        #expect(list.count == 2)
    }

    @Test func openAfterEmptyingListWorks() {
        var (list, ids) = makeList(["a"])
        list.close(ids[0])
        let id = list.open(makeTab("b"))
        #expect(list.activeID == id)
        #expect(titles(list) == ["b"])
    }

    @Test func moveForwardAndBack() {
        var (list, ids) = makeList(["a", "b", "c", "d"])
        let ok6 = list.move(ids[0], to: 2)
        #expect(ok6)
        #expect(titles(list) == ["b", "c", "a", "d"])
        let ok7 = list.move(ids[3], to: 0)
        #expect(ok7)
        #expect(titles(list) == ["d", "b", "c", "a"])
    }

    @Test func moveClampsDestination() {
        var (list, ids) = makeList(["a", "b", "c"])
        list.move(ids[0], to: 99)
        #expect(titles(list) == ["b", "c", "a"])
        list.move(ids[0], to: -5)
        #expect(titles(list) == ["a", "b", "c"])
    }

    @Test func moveKeepsActiveTab() {
        var (list, ids) = makeList(["a", "b", "c"])
        list.select(ids[1])
        list.move(ids[1], to: 0)
        #expect(list.activeID == ids[1])
        #expect(list.activeIndex == 0)
    }

    @Test func moveUnknownIDChangesNothing() {
        var (list, _) = makeList(["a", "b"])
        let ok8 = list.move(BrowserTabID(), to: 0)
        #expect(!ok8)
        #expect(titles(list) == ["a", "b"])
    }

    @Test func engineSnapshotUpdatesTabFields() {
        var (list, ids) = makeList(["a"])
        let state = EngineTabState(
            tabID: 7, url: URL(string: "https://b.example/x"), title: "B",
            faviconURL: URL(string: "https://b.example/f.ico"), isLoading: true, canGoBack: true,
            canGoForward: true)
        let ok9 = list.update(ids[0], from: state)
        #expect(ok9)
        let tab = list.tab(id: ids[0])
        #expect(tab?.id == ids[0])
        #expect(tab?.url?.absoluteString == "https://b.example/x")
        #expect(tab?.title == "B")
        #expect(tab?.faviconURL?.absoluteString == "https://b.example/f.ico")
        #expect(tab?.isLoading == true)
        #expect(tab?.canGoBack == true)
        #expect(tab?.canGoForward == true)
        let ok10 = list.update(BrowserTabID(), from: state)
        #expect(!ok10)
    }

    @Test func roundTripsThroughJSON() throws {
        var (list, ids) = makeList(["a", "b", "c"])
        list.select(ids[1])
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(TabList.self, from: data)
        #expect(decoded == list)
        #expect(decoded.activeID == ids[1])
    }

    @Test func emptyListRoundTrips() throws {
        let data = try JSONEncoder().encode(TabList())
        #expect(try JSONDecoder().decode(TabList.self, from: data) == TabList())
    }

    @Test func decodingRejectsInconsistentLists() throws {
        let tab = makeTab("a")
        #expect(TabList(tabs: [tab], activeID: BrowserTabID()) == nil)
        #expect(TabList(tabs: [], activeID: tab.id) == nil)
        #expect(TabList(tabs: [tab, tab], activeID: tab.id) == nil)
        let bad = try JSONEncoder().encode(Fixture(tabs: [tab], activeID: BrowserTabID()))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TabList.self, from: bad) }
    }

    // A window whose Space on screen has no tab selected still lists the Favorites it shows.

    @Test func listsTabsWithNoActiveTab() throws {
        let tabs = [makeTab("a"), makeTab("b")]
        let list = try #require(TabList(tabs: tabs, activeID: nil))
        #expect(titles(list) == ["a", "b"])
        #expect(list.activeID == nil)
        #expect(list.activeTab == nil)
        #expect(list.activeIndex == nil)
        #expect(list.tab(id: tabs[1].id)?.title == "b")
    }

    @Test func noActiveTabSurvivesClosingAndMovingOthers() throws {
        let tabs = [makeTab("a"), makeTab("b"), makeTab("c")]
        var list = try #require(TabList(tabs: tabs, activeID: nil))
        let closed = list.close(tabs[0].id)
        let moved = list.move(tabs[2].id, to: 0)
        #expect(closed && moved)
        #expect(titles(list) == ["c", "b"])
        #expect(list.activeID == nil)
    }

    @Test func selectingOrOpeningInAListWithNoActiveTabActivates() throws {
        let tabs = [makeTab("a"), makeTab("b")]
        var list = try #require(TabList(tabs: tabs, activeID: nil))
        let selected = list.select(tabs[1].id)
        #expect(selected && list.activeID == tabs[1].id)

        var other = try #require(TabList(tabs: tabs, activeID: nil))
        let id = other.open(makeTab("c"), at: .afterActive, activate: false)
        // With no active tab, after the active one means the end.
        #expect(titles(other) == ["a", "b", "c"])
        #expect(other.activeID == id)
    }

    @Test func listWithNoActiveTabRoundTrips() throws {
        let list = try #require(TabList(tabs: [makeTab("a")], activeID: nil))
        let data = try JSONEncoder().encode(list)
        #expect(try JSONDecoder().decode(TabList.self, from: data) == list)
    }

    private struct Fixture: Codable {
        var tabs: [BrowserTab]
        var activeID: BrowserTabID
    }
}
