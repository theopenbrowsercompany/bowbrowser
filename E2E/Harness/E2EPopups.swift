import Foundation

/// The window's popup handling as a test sees it: the tabs the pages of a window open, read from the window's tab
/// list. E2E/Harness/E2EAppAdapter+Popups.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EPopupsApp: E2EApp {
    /// The titles of the tabs of the Space on screen in `page`'s window, in sidebar order.
    func popupTabTitles(besides page: any E2EPage) throws -> [String]
    /// The title of the tab `page`'s window shows, or nil when it shows none.
    func shownPopupTabTitle(besides page: any E2EPage) throws -> String?
    /// The popup panels open over `page`'s window, oldest first.
    func popupPanels(besides page: any E2EPage) throws -> [E2EPopupPanel]
    /// Closes the oldest popup panel over `page`'s window the way its close button does (the page is asked first).
    func closePopupPanel(besides page: any E2EPage) throws
    /// Waits until no popup panel is open over `page`'s window, and throws when one is still open as the wait's
    /// budget runs out.
    func untilNoPopupPanels(besides page: any E2EPage) async throws
}

/// A popup panel as a test sees it.
struct E2EPopupPanel: Equatable {
    /// The size of the page area, in points.
    var contentSize: CGSize
    /// True while the panel is a child window of the browser window that opened it.
    var attached: Bool
    /// True when the panel would show on a screen or has taken keyboard focus.
    var intrudes: Bool
    var title: String
    /// The panel window's frame and its browser window's, for failure messages.
    var frame: CGRect
    var parentFrame: CGRect
}
