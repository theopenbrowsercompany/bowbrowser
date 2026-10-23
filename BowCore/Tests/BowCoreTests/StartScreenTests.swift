import Foundation
import Testing

@testable import BowCore

@Suite struct StartScreenTests {
    @Test func theGreetingFollowsTheHourWithItsEdges() {
        let expected: [(Int, StartScreen.Greeting)] = [
            (0, .evening), (4, .evening), (5, .morning), (11, .morning), (12, .afternoon), (17, .afternoon),
            (18, .evening), (23, .evening), (24, .evening), (29, .morning), (-1, .evening),
        ]
        for (hour, greeting) in expected {
            #expect(StartScreen.Greeting(hour: hour) == greeting, "hour \(hour)")
        }
        #expect(StartScreen.Greeting.morning.rawValue == "Good morning")
        #expect(StartScreen.Greeting.afternoon.rawValue == "Good afternoon")
        #expect(StartScreen.Greeting.evening.rawValue == "Good evening")
    }

    @Test func theGreetingReadsTheHourInTheCalendarsTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 13)))
        #expect(StartScreen.Greeting(hour: StartScreen.hour(at: date, calendar: calendar)) == .afternoon)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: -6 * 3600))
        #expect(StartScreen.Greeting(hour: StartScreen.hour(at: date, calendar: calendar)) == .morning)
    }

    @Test func theHintCountsTabsWithPluralsAndCutsALongName() {
        #expect(StartScreen.hint(spaceName: "Work Space", tabCount: 4) == "Work Space · 4 tabs · press ⌘T to search")
        #expect(StartScreen.hint(spaceName: "Work", tabCount: 1) == "Work · 1 tab · press ⌘T to search")
        #expect(StartScreen.hint(spaceName: "Work", tabCount: 0) == "Work · 0 tabs · press ⌘T to search")
        #expect(StartScreen.hint(spaceName: "  Home \n", tabCount: -2) == "Home · 0 tabs · press ⌘T to search")
        #expect(StartScreen.hint(spaceName: " ", tabCount: 2) == "Space · 2 tabs · press ⌘T to search")
        let long = String(repeating: "a", count: 41)
        let cut = String(repeating: "a", count: 39) + "…"
        #expect(StartScreen.hint(spaceName: long, tabCount: 3) == "\(cut) · 3 tabs · press ⌘T to search")
        let exact = String(repeating: "b", count: 40)
        #expect(StartScreen.hint(spaceName: exact, tabCount: 3) == "\(exact) · 3 tabs · press ⌘T to search")
    }

    @Test func theHintNamesTheSpaceAndCountsItsPinnedAndTodayTabsButNotFavorites() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let space = try #require(store.graph.activeSpace)
            try store.renameSpace(space.id, to: "Work Space")
            #expect(StartScreen.hint(for: space.id, in: store.graph) == "Work Space · 0 tabs · press ⌘T to search")
            try store.addFavorite(url: "https://fav.example")
            let folderItem = SidebarItem.folder(title: "F")
            try store.apply([
                .insert(.tab(url: "https://a.example"), parent: space.pinnedContainerID, index: nil),
                .insert(folderItem, parent: space.pinnedContainerID, index: nil),
                .insert(.tab(url: "https://b.example"), parent: folderItem.id, index: nil),
                .insert(.tab(url: "https://c.example"), parent: space.unpinnedContainerID, index: nil),
            ])
            #expect(StartScreen.hint(for: space.id, in: store.graph) == "Work Space · 3 tabs · press ⌘T to search")
        }
    }

    @Test func quickLinksAreTheFirstSixFavoritesInSidebarOrder() throws {
        #expect(StartScreen.quickLinks(from: [Int]()).isEmpty)
        #expect(StartScreen.quickLinks(from: [1, 2, 3]) == [1, 2, 3])
        #expect(StartScreen.quickLinks(from: Array(1...12)) == [1, 2, 3, 4, 5, 6])
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            #expect(StartScreen.quickLinks(in: store.graph).isEmpty)
            var added: [SidebarItemID] = []
            for index in 0..<8 { added.append(try store.addFavorite(url: "https://\(index).example")) }
            let last = try store.addFavorite(url: "https://first.example", at: 0)
            #expect(StartScreen.quickLinks(in: store.graph) == [last] + added.prefix(5))
            try store.createSpace(title: "Client", profileID: "client-profile")
            #expect(StartScreen.quickLinks(in: store.graph).isEmpty)
        }
    }
}
