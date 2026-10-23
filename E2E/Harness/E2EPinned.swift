import Foundation

/// Pinned tabs as a test sees them: a tab row's context menu, the "Back to Pinned URL" button on a pinned row and the
/// address a pinned tab is saved with. E2E/Harness/E2EAppAdapter+Pinned.swift implements it; each action goes through
/// the control a person uses and is refused once the test has ended.
@MainActor
protocol E2EPinnedApp: E2EZonesApp {
    /// The titles of the context menu items of `page`'s tab row, top to bottom ("-" for a separator).
    func tabMenu(of page: any E2EPage) throws -> [String]
    /// Chooses the item titled `title` in the context menu of `page`'s tab row; throws when there is none.
    func chooseTabMenuItem(_ title: String, of page: any E2EPage) throws
    /// Whether `page`'s tab row shows the "Back to Pinned URL" button.
    func showsBackToPinned(_ page: any E2EPage) throws -> Bool
    /// Clicks the "Back to Pinned URL" button on `page`'s tab row; throws when it is not showing.
    func clickBackToPinned(_ page: any E2EPage) throws
    /// The address `page`'s tab is saved with in the sidebar store (what a pinned tab returns to), empty for none.
    func savedURL(of page: any E2EPage) throws -> String
    /// The saved title of the active tab of `page`'s window in the sidebar store, nil for none.
    func activeTabTitle(of page: any E2EPage) throws -> String?
}
