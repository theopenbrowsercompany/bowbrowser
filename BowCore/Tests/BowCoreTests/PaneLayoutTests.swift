import Testing

@testable import BowCore

@Suite struct PaneLayoutTests {
    private func approx(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    @Test func acceptsOneToFourPanes() throws {
        for count in 1...4 {
            let tabs = Array(0..<count)
            let layout = try #require(PaneLayout(tabs: tabs, focused: count - 1))
            #expect(layout.tabs == tabs)
            #expect(layout.focusedIndex == count - 1)
            #expect(approx(layout.fractions, Array(repeating: 1 / Double(count), count: count)))
            #expect(layout.isSplit == (count > 1))
        }
    }

    @Test func refusesBadLayouts() {
        #expect(PaneLayout<Int>(tabs: [], focused: 0) == nil)
        #expect(PaneLayout(tabs: [1, 2, 3, 4, 5], focused: 1) == nil)
        #expect(PaneLayout(tabs: [1, 1], focused: 1) == nil)
        #expect(PaneLayout(tabs: [1, 2], focused: 3) == nil)
    }

    @Test func fractionsThatDoNotFitGiveEqualPanes() throws {
        #expect(approx(try #require(PaneLayout(tabs: [1, 2], focused: 1, fractions: [1])).fractions, [0.5, 0.5]))
        #expect(approx(try #require(PaneLayout(tabs: [1, 2], focused: 1, fractions: [1, -1])).fractions, [0.5, 0.5]))
        #expect(
            approx(try #require(PaneLayout(tabs: [1, 2], focused: 1, fractions: [.nan, 1])).fractions, [0.5, 0.5]))
    }

    @Test func fractionsAreNormalizedWithAMinimum() throws {
        #expect(
            approx(try #require(PaneLayout(tabs: [1, 2], focused: 1, fractions: [3, 1])).fractions, [0.75, 0.25]))
        let tiny = try #require(PaneLayout(tabs: [1, 2], focused: 1, fractions: [0.01, 0.99])).fractions
        #expect(approx(tiny, [SidebarSplit.minimumPaneFraction, 1 - SidebarSplit.minimumPaneFraction]))
    }

    @Test func reconcileWithNoActiveTabShowsNone() throws {
        let layout = try #require(PaneLayout(tabs: [1, 2], focused: 1))
        #expect(layout.reconciled(active: nil, showable: { _ in true }) == nil)
    }

    @Test func reconcileWithAnotherActiveTabReturnsToOnePane() throws {
        let layout = try #require(PaneLayout(tabs: [1, 2], focused: 1))
        #expect(layout.reconciled(active: 3, showable: { _ in true }) == .single(3))
    }

    @Test func reconcileMovesFocusToTheActivePane() throws {
        let layout = try #require(PaneLayout(tabs: [1, 2, 3], focused: 1, fractions: [2, 1, 1]))
        let next = try #require(layout.reconciled(active: 3, showable: { _ in true }))
        #expect(next.tabs == [1, 2, 3])
        #expect(next.focused == 3)
        #expect(approx(next.fractions, layout.fractions))
    }

    @Test func reconcileDropsPanesThatCannotShowAndSharesTheirWidth() throws {
        let layout = try #require(PaneLayout(tabs: [1, 2, 3], focused: 1, fractions: [2, 1, 1]))
        let next = try #require(layout.reconciled(active: 1, showable: { $0 != 2 }))
        #expect(next.tabs == [1, 3])
        #expect(approx(next.fractions, [2.0 / 3, 1.0 / 3]))
    }

    @Test func reconcileKeepsTheActivePaneEvenWhenNotShowable() throws {
        let layout = try #require(PaneLayout(tabs: [1, 2], focused: 2))
        let next = try #require(layout.reconciled(active: 1, showable: { _ in false }))
        #expect(next == .single(1))
    }

    @Test func focusAfterClosingPicksTheNeighbour() throws {
        let layout = try #require(PaneLayout(tabs: [1, 2, 3], focused: 2))
        #expect(layout.focusAfterClosing(1) == 2)
        #expect(layout.focusAfterClosing(2) == 1)
        #expect(layout.focusAfterClosing(3) == 2)
        #expect(layout.focusAfterClosing(4) == nil)
        #expect(PaneLayout.single(1).focusAfterClosing(1) == nil)
    }

    @Test func panesSitSideBySideUnlessStacked() throws {
        #expect(try #require(PaneLayout(tabs: [1, 2], focused: 1)).orientation == .horizontal)
        let stacked = try #require(PaneLayout(tabs: [1, 2, 3], focused: 2, orientation: .vertical))
        #expect(stacked.orientation == .vertical)
        // A pane leaving keeps the others stacked.
        let reconciled = try #require(stacked.reconciled(active: 2) { $0 != 3 })
        #expect(reconciled.tabs == [1, 2])
        #expect(reconciled.orientation == .vertical)
    }

    @Test func resizingKeepsFocusAndLayoutAndRefusesSharesThatDoNotFit() throws {
        let stacked = try #require(PaneLayout(tabs: [1, 2], focused: 2, orientation: .vertical))
        let resized = try #require(stacked.resized([0.7, 0.3]))
        #expect(approx(resized.fractions, [0.7, 0.3]))
        #expect(resized.focused == 2)
        #expect(resized.orientation == .vertical)
        #expect(stacked.resized([1]) == nil)
        #expect(stacked.resized([1, 0]) == nil)
        #expect(stacked.resized([.nan, 1]) == nil)
    }
}

@Suite struct PaneDividerDragTests {
    @Test func aDragReportsOnceWhenItEndsWithWhereItEnded() {
        var drag = PaneDividerDrag()
        drag.began()
        #expect(drag.isDragging)
        #expect(drag.moved([0.6, 0.4]) == nil)
        #expect(drag.moved([0.65, 0.35]) == nil)
        #expect(drag.moved([0.7, 0.3]) == nil)
        #expect(drag.ended() == [0.7, 0.3])
        #expect(!drag.isDragging)
        // Nothing is left over for the next drag.
        #expect(drag.ended() == nil)
    }

    @Test func aDragThatMovedNothingReportsNothing() {
        var drag = PaneDividerDrag()
        drag.began()
        #expect(drag.ended() == nil)
    }

    @Test func aDividerMovedOutsideADragReportsAtOnce() {
        var drag = PaneDividerDrag()
        #expect(drag.moved([0.3, 0.7]) == [0.3, 0.7])
        #expect(drag.ended() == nil)
    }

    @Test func aNewDragForgetsAnEarlierOneThatNeverEnded() {
        var drag = PaneDividerDrag()
        drag.began()
        _ = drag.moved([0.6, 0.4])
        drag.began()
        #expect(drag.ended() == nil)
    }
}
