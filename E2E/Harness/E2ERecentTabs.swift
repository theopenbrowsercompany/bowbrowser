import Foundation

// The Ctrl+Tab switcher as a test sees it. Ctrl+Tab, Shift+Ctrl+Tab and Escape reach the window the way the engine
// hands a key to it before the page (`BrowserWindowController.tab(_:handleKeyBeforePage:)`, the method the engine's
// key hook calls), and the Ctrl release is a native flagsChanged event sent through the application, which is where
// the switcher's event monitor hears it. Never through DevTools.

/// What the switcher's overlay shows.
struct E2ERecentTabsState: Equatable, CustomStringConvertible {
    var isShown: Bool
    /// One entry per row: "Title" or "Title @ Space name".
    var rows: [String]
    /// The highlighted row, nil when none shows.
    var highlighted: Int?
    /// Whether a flags monitor is installed (it must exist only while the overlay shows).
    var monitoring: Bool

    var description: String {
        "shown=\(isShown) rows=\(rows) highlighted=\(highlighted.map(String.init) ?? "none") monitoring=\(monitoring)"
    }
}

@MainActor
protocol E2ERecentTabsApp: E2EApp {
    /// Clicks the sidebar row of the tab with store ID `item` in the Space on screen, as a person does.
    func clickTabRow(_ item: String, in page: any E2EPage) throws
    /// Sends Ctrl+Tab (`shift` false) or Ctrl+Shift+Tab to the window as the engine does before the page sees it.
    /// Returns whether the app claimed the key.
    func pressRecentTabs(shift: Bool, in page: any E2EPage) throws -> Bool
    /// Sends Escape the same way. Returns whether the app claimed the key.
    func pressEscapeBeforePage(in page: any E2EPage) throws -> Bool
    /// Releases Ctrl: a native flagsChanged event with no modifiers, sent through the application.
    func releaseControl(in page: any E2EPage) throws
    /// The overlay as shown now.
    func recentTabs(of page: any E2EPage) throws -> E2ERecentTabsState
}
