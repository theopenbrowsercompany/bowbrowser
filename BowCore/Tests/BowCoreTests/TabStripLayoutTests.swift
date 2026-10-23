import BowCore
import Testing

@Suite struct TabStripLayoutTests {
    @Test func pillsKeepTheirWidthWhileTheyFit() {
        #expect(TabStripLayout.width(count: 3, available: 1000) == 190)
        // Exactly full: 4 pills and 3 gaps.
        #expect(TabStripLayout.width(count: 4, available: 4 * 190 + 3 * 8) == 190)
        #expect(TabStripLayout.width(count: 0, available: 0) == 190)
    }

    @Test func crowdedPillsShrinkEvenly() {
        let width = TabStripLayout.width(count: 5, available: 900)
        #expect(abs(width - 173.6) < 0.001)
        #expect(width < 190 && width > TabStripLayout.minPillWidth)
        // All pills together fill the available width exactly.
        #expect(abs(TabStripLayout.contentWidth(count: 5, pillWidth: width) - 900) < 0.001)
    }

    @Test func pillsStopAtTheMinimum() {
        #expect(TabStripLayout.width(count: 30, available: 900) == TabStripLayout.minPillWidth)
        #expect(TabStripLayout.width(count: 1, available: 10) == TabStripLayout.minPillWidth)
    }

    @Test func leadingInsetFollowsTheWindowButtons() {
        #expect(TabStripLayout.leadingInset(buttonsTrailingEdge: 68) == 78)
    }

    @Test func scrollRevealsTheShownPillWithTheLeastMovement() {
        let w = TabStripLayout.minPillWidth
        // 10 pills in a 400 wide viewport: content is 10 * 96 + 9 * 8 = 1032.
        func offset(_ index: Int, _ current: Double) -> Double {
            TabStripLayout.scrollOffset(revealing: index, count: 10, pillWidth: w, viewport: 400, current: current)
        }
        #expect(offset(0, 0) == 0)
        // Already visible: unchanged.
        #expect(offset(2, 0) == 0)
        // Off to the right: its trailing edge meets the viewport's.
        #expect(offset(5, 0) == 5 * (w + 8) + w - 400)
        // Off to the left: its leading edge meets the viewport's.
        #expect(offset(1, 500) == w + 8)
        // The last pill ends at the content's end.
        #expect(offset(9, 0) == 1032 - 400)
        // Content narrower than the viewport never scrolls.
        #expect(
            TabStripLayout.scrollOffset(revealing: 1, count: 2, pillWidth: 190, viewport: 800, current: 30) == 0)
    }
}
