import Foundation
import Testing

@testable import BowCore

@Suite struct RecencySwitchTests {
    @Test func stepForwardWalksTheOrder() throws {
        var switcher = try #require(RecencySwitch(order: ["A", "B", "C"]))
        switcher.step(1)
        #expect(switcher.selected == "B")
        switcher.step(1)
        #expect(switcher.selected == "C")
    }

    @Test func stepForwardWrapsToTheFront() throws {
        var switcher = try #require(RecencySwitch(order: ["A", "B", "C"]))
        switcher.step(1)
        switcher.step(1)
        switcher.step(1)
        #expect(switcher.selected == "A")
        #expect(switcher.index == 0)
    }

    @Test func stepBackWrapsToTheEnd() throws {
        var switcher = try #require(RecencySwitch(order: ["A", "B", "C"]))
        switcher.step(-1)
        #expect(switcher.selected == "C")
        switcher.step(-1)
        #expect(switcher.selected == "B")
    }

    @Test func largeStepsStillWrap() throws {
        var switcher = try #require(RecencySwitch(order: ["A", "B", "C"]))
        switcher.step(7)
        #expect(switcher.selected == "B")
        switcher.step(-5)
        #expect(switcher.selected == "C")
    }

    @Test func hugeStepsDoNotOverflow() throws {
        var switcher = try #require(RecencySwitch(order: ["A", "B", "C"]))
        switcher.step(1)
        switcher.step(Int.max)
        #expect(switcher.index == (1 + Int.max % 3) % 3)
        switcher.step(Int.min)
        #expect(switcher.index >= 0 && switcher.index < 3)
    }

    @Test func singleItemStaysPut() throws {
        var switcher = try #require(RecencySwitch(order: ["A"]))
        switcher.step(1)
        #expect(switcher.selected == "A")
        switcher.step(-1)
        #expect(switcher.selected == "A")
    }

    @Test func emptyOrderHasNoSwitch() {
        #expect(RecencySwitch<String>(order: []) == nil)
    }

    @Test func switchSnapshotIgnoresLaterUse() throws {
        var list = RecencyList<String>()
        list.use("A")
        list.use("B")
        let switcher = try #require(list.beginSwitch())
        list.use("C")
        #expect(switcher.order == ["B", "A"])
    }
}
