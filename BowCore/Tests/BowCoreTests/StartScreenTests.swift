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

    @Test func theHintNamesTheSpaceWithoutACountAndCutsALongName() {
        #expect(StartScreen.hint(spaceName: "Work Space") == "Work Space · press ⌘T to search")
        #expect(StartScreen.hint(spaceName: "  Home \n") == "Home · press ⌘T to search")
        #expect(StartScreen.hint(spaceName: " ") == "Space · press ⌘T to search")
        let long = String(repeating: "a", count: 41)
        let cut = String(repeating: "a", count: 39) + "…"
        #expect(StartScreen.hint(spaceName: long) == "\(cut) · press ⌘T to search")
        let exact = String(repeating: "b", count: 40)
        #expect(StartScreen.hint(spaceName: exact) == "\(exact) · press ⌘T to search")
    }

    @Test func theHintForASpaceReadsItsNameAndFollowsARename() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: folder.appendingPathComponent("Sidebar.json"))
            let space = try #require(store.graph.activeSpace)
            try store.renameSpace(space.id, to: "Work Space")
            #expect(StartScreen.hint(for: space.id, in: store.graph) == "Work Space · press ⌘T to search")
            try store.renameSpace(space.id, to: "Side")
            #expect(StartScreen.hint(for: space.id, in: store.graph) == "Side · press ⌘T to search")
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
