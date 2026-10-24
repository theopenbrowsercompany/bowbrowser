import Testing

@testable import BowCore

@Suite struct FindMatchTrackerTests {
    private func started(_ text: String = "bow", count: Int) -> FindMatchTracker {
        var tracker = FindMatchTracker()
        _ = tracker.find(text, forward: true, matchCase: false)
        _ = tracker.counted(text: text, count: count)
        return tracker
    }

    private func result(_ active: Int, of count: Int) -> FindResult {
        FindResult(matchCount: count, activeMatch: active, isFinal: true)
    }

    @Test func newSearchShowsOneOfNOnceCounted() {
        var tracker = FindMatchTracker()
        let update = tracker.find("bow", forward: true, matchCase: false)
        #expect(update.action == .startSearch(text: "bow", matchCase: false))
        #expect(update.result == nil)
        #expect(tracker.counted(text: "bow", count: 4) == result(1, of: 4))
    }

    @Test func zeroMatchesStaysAtZeroOfZero() {
        var tracker = FindMatchTracker()
        _ = tracker.find("zzz", forward: true, matchCase: false)
        #expect(tracker.counted(text: "zzz", count: 0) == result(0, of: 0))
        #expect(tracker.find("zzz", forward: true, matchCase: false).result == result(0, of: 0))
        #expect(tracker.find("zzz", forward: false, matchCase: false).result == result(0, of: 0))
    }

    @Test func oneMatchStaysAtOneOfOne() {
        var tracker = started(count: 1)
        #expect(tracker.find("bow", forward: true, matchCase: false).result == result(1, of: 1))
        #expect(tracker.find("bow", forward: false, matchCase: false).result == result(1, of: 1))
    }

    @Test func forwardWrapsFromLastToFirst() {
        var tracker = started(count: 4)
        var seen = [1]
        for _ in 0..<4 {
            let update = tracker.find("bow", forward: true, matchCase: false)
            #expect(update.action == .step(forward: true))
            seen.append(update.result?.activeMatch ?? -1)
        }
        #expect(seen == [1, 2, 3, 4, 1])
    }

    @Test func backWrapsFromFirstToLast() {
        var tracker = started(count: 4)
        #expect(tracker.find("bow", forward: false, matchCase: false).result == result(4, of: 4))
        #expect(tracker.find("bow", forward: false, matchCase: false).result == result(3, of: 4))
    }

    @Test func stepsBeforeTheCountAreAppliedOnceItArrives() {
        var forward = FindMatchTracker()
        _ = forward.find("bow", forward: true, matchCase: false)
        #expect(forward.find("bow", forward: true, matchCase: false).result == nil)
        #expect(forward.find("bow", forward: true, matchCase: false).result == nil)
        #expect(forward.counted(text: "bow", count: 3) == result(3, of: 3))

        var back = FindMatchTracker()
        _ = back.find("bow", forward: true, matchCase: false)
        _ = back.find("bow", forward: false, matchCase: false)
        #expect(back.counted(text: "bow", count: 4) == result(4, of: 4))
    }

    @Test func staleCountIsIgnored() {
        var tracker = FindMatchTracker()
        _ = tracker.find("bo", forward: true, matchCase: false)
        _ = tracker.find("bow", forward: true, matchCase: false)
        #expect(tracker.counted(text: "bo", count: 9) == nil)
        #expect(tracker.counted(text: "bow", count: 2) == result(1, of: 2))
    }

    @Test func countWithNoSearchIsIgnored() {
        var tracker = FindMatchTracker()
        #expect(tracker.counted(text: "bow", count: 3) == nil)
    }

    @Test func recountKeepsTheActiveMatch() {
        var tracker = started(count: 5)
        _ = tracker.find("bow", forward: true, matchCase: false)
        _ = tracker.find("bow", forward: true, matchCase: false)
        #expect(tracker.counted(text: "bow", count: 6) == result(3, of: 6))
    }

    @Test func recountThatShrinksBelowTheActiveMatchClamps() {
        var tracker = started(count: 5)
        for _ in 0..<4 { _ = tracker.find("bow", forward: true, matchCase: false) }
        #expect(tracker.counted(text: "bow", count: 2) == result(2, of: 2))
        #expect(tracker.counted(text: "bow", count: 0) == result(0, of: 0))
    }

    @Test func textChangeRestartsAtOne() {
        var tracker = started(count: 4)
        _ = tracker.find("bow", forward: true, matchCase: false)
        let update = tracker.find("bows", forward: true, matchCase: false)
        #expect(update.action == .startSearch(text: "bows", matchCase: false))
        #expect(update.result == nil)
        #expect(tracker.counted(text: "bows", count: 3) == result(1, of: 3))
    }

    @Test func matchCaseChangeRestartsAtOne() {
        var tracker = started(count: 4)
        _ = tracker.find("bow", forward: true, matchCase: false)
        let update = tracker.find("bow", forward: true, matchCase: true)
        #expect(update.action == .startSearch(text: "bow", matchCase: true))
        #expect(tracker.counted(text: "bow", count: 2) == result(1, of: 2))
    }

    @Test func emptyTextStopsWithANilResult() {
        var tracker = started(count: 4)
        let update = tracker.find("", forward: true, matchCase: false)
        #expect(update.action == .stop)
        #expect(update.result == nil)
        #expect(tracker.counted(text: "bow", count: 4) == nil)
    }

    @Test func sameTextAfterAStopStartsAtOne() {
        var tracker = started(count: 4)
        _ = tracker.find("bow", forward: true, matchCase: false)
        _ = tracker.find("", forward: true, matchCase: false)
        let update = tracker.find("bow", forward: true, matchCase: false)
        #expect(update.action == .startSearch(text: "bow", matchCase: false))
        #expect(tracker.counted(text: "bow", count: 4) == result(1, of: 4))
    }

    @Test func pageChangeThenSameTextRecountsAtOne() {
        var tracker = started(count: 4)
        _ = tracker.find("bow", forward: true, matchCase: false)
        tracker.pageChanged()
        let update = tracker.find("bow", forward: true, matchCase: false)
        #expect(update.action == .startSearch(text: "bow", matchCase: false))
        #expect(update.result == nil)
        #expect(tracker.counted(text: "bow", count: 7) == result(1, of: 7))
    }

    @Test func pageChangeIgnoresALateCountForTheOldDocument() {
        var tracker = FindMatchTracker()
        _ = tracker.find("bow", forward: true, matchCase: false)
        tracker.pageChanged()
        #expect(tracker.counted(text: "bow", count: 4) == nil)
    }
}
