import Foundation

/// The window's popup handling as a test sees it: the tabs the pages of a window open, read from the window's tab
/// list. E2E/Harness/E2EAppAdapter+Popups.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EPopupsApp: E2EApp {
    /// The titles of the tabs of the Space on screen in `page`'s window, in sidebar order.
    func popupTabTitles(besides page: any E2EPage) throws -> [String]
    /// The title of the tab `page`'s window shows, or nil when it shows none.
    func shownPopupTabTitle(besides page: any E2EPage) throws -> String?
}
