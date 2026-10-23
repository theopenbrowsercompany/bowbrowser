import BowCore
import Testing

@Suite struct WindowLayoutTests {
    @Test func unknownOrMissingStoredValueIsTheSidebarLayout() {
        #expect(WindowLayout(stored: nil) == .sidebar)
        #expect(WindowLayout(stored: "bogus") == .sidebar)
        #expect(WindowLayout(stored: "topTabs") == .topTabs)
        #expect(WindowLayout(stored: WindowLayout.sidebar.rawValue) == .sidebar)
    }

    @Test func togglingSwitchesBetweenTheTwo() {
        #expect(WindowLayout.sidebar.toggled == .topTabs)
        #expect(WindowLayout.topTabs.toggled == .sidebar)
    }

    @Test func sidebarLayoutKeepsTodaysInsets() {
        let insets = WindowLayout.sidebar.pageInsets(showsToolbar: true)
        #expect(insets == (8, 0, 8, 8))
        #expect(WindowLayout.sidebar.pageInsets(showsToolbar: false) == insets)
    }

    @Test func topTabsCardSitsUnderTheStripAndToolbarRow() {
        #expect(WindowLayout.topTabs.pageInsets(showsToolbar: true) == (90, 8, 8, 8))
        // Hiding the toolbar leaves the strip and the card's own inset.
        #expect(WindowLayout.topTabs.pageInsets(showsToolbar: false) == (54, 8, 8, 8))
    }
}
