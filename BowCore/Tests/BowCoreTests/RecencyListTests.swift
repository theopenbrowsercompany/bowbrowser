import Foundation
import Testing

@testable import BowCore

@Suite struct RecencyListTests {
    @Test func startsEmpty() {
        let list = RecencyList<String>()
        #expect(list.ids.isEmpty)
        #expect(list.beginSwitch() == nil)
    }

    @Test func usedItemsGoToTheFront() {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        list.use("C")
        #expect(list.ids == ["C", "B", "A"])
    }

    @Test func reusingAnItemMovesItWithoutDuplicating() {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        list.use("C")
        list.use("A")
        #expect(list.ids == ["A", "C", "B"])
    }

    @Test func removeDropsAClosedItem() {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        list.remove("A")
        #expect(list.ids == ["B"])
        #expect(!list.contains("A"))
    }

    @Test func removingAnUnlistedItemDoesNothing() {
        var list = RecencyList<String>()
        list.use("A")
        list.remove("Z")
        #expect(list.ids == ["A"])
    }

    @Test func capDropsTheLeastRecentItems() {
        var list = RecencyList<String>(maxCount: 2)
        list.use("A")
        list.use("B")
        list.use("C")
        #expect(list.ids == ["C", "B"])
        list.use("B")
        list.use("D")
        #expect(list.ids == ["D", "B"])
    }

    @Test func noCapKeepsEveryItem() {
        var list = RecencyList<Int>()
        for id in 0..<500 {
            list.use(id)
        }
        #expect(list.ids.count == 500)
        #expect(list.ids.first == 499)
    }

    @Test func capOfOneKeepsOnlyTheLatestItem() {
        var list = RecencyList<String>(maxCount: 1)
        list.use("A")
        list.use("B")
        #expect(list.ids == ["B"])
    }

    @Test func switchStartsOnTheMostRecentItem() throws {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        let switcher = try #require(list.beginSwitch())
        #expect(switcher.order == ["B", "A"])
        #expect(switcher.selected == "B")
    }

    @Test func oneTabStepReachesThePreviousItem() throws {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        list.use("C")
        var switcher = try #require(list.beginSwitch())
        switcher.step(1)
        #expect(switcher.selected == "B")
    }

    @Test func committingMakesTheChosenItemMostRecent() throws {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        list.use("C")
        #expect(list.ids == ["C", "B", "A"])

        var switcher = try #require(list.beginSwitch())
        switcher.step(1)
        #expect(list.commit(switcher) == "B")
        #expect(list.ids == ["B", "C", "A"])
    }

    @Test func committingWithoutSteppingKeepsTheCurrentItemOnTop() throws {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        let switcher = try #require(list.beginSwitch())
        #expect(list.commit(switcher) == "B")
        #expect(list.ids == ["B", "A"])
    }

    @Test func closedHighlightedItemFallsForwardToAnOpenOne() throws {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        list.use("C")
        // Order is C, B, A and the switch highlights B.
        var switcher = try #require(list.beginSwitch())
        switcher.step(1)
        list.remove("B")
        #expect(list.commit(switcher) == "A")
        #expect(list.ids == ["A", "C"])
    }

    @Test func committingWhenEveryItemClosedLeavesTheListUnchanged() throws {
        var list = RecencyList<String>()
        list.use("A")
        let switcher = try #require(list.beginSwitch())
        list.remove("A")
        #expect(list.commit(switcher) == nil)
        #expect(list.ids.isEmpty)
    }

    @Test func keepOnlyDropsTabsThatNoLongerExist() {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        list.use("C")
        list.keepOnly(["A", "C"])
        #expect(list.ids == ["C", "A"])
    }

    @Test func codableRoundTripKeepsOrderAndCap() throws {
        var list = RecencyList<String>(maxCount: 3)
        list.use("A")
        list.use("B")
        list.use("C")
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(RecencyList<String>.self, from: data)
        #expect(decoded == list)
        #expect(decoded.ids == ["C", "B", "A"])
        #expect(decoded.maxCount == 3)
    }

    @Test func decodingDropsDuplicatesKeepingTheMostRecent() throws {
        let json = #"{"ids":["A","B","A","C"]}"#
        let decoded = try JSONDecoder().decode(RecencyList<String>.self, from: Data(json.utf8))
        #expect(decoded.ids == ["A", "B", "C"])
        #expect(decoded.maxCount == nil)
    }

    @Test func decodingAppliesTheCap() throws {
        let json = #"{"ids":["A","B","C","D"],"maxCount":2}"#
        let decoded = try JSONDecoder().decode(RecencyList<String>.self, from: Data(json.utf8))
        #expect(decoded.ids == ["A", "B"])
    }

    @Test func decodingRejectsACapBelowOne() {
        let json = #"{"ids":["A"],"maxCount":0}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecencyList<String>.self, from: Data(json.utf8))
        }
    }
}
