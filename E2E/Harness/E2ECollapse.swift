import Foundation

/// Collapsing every folder (View > Collapse All Folders, or the same action in the command bar) as a test sees it.
@MainActor
protocol E2ECollapseApp: E2EFoldersApp, E2ECommandBarApp, E2EMenuApp {
    /// Chooses View > Collapse All Folders in `page`'s window, after the item validates, as a click does. Throws
    /// when the item is missing or disabled.
    func chooseCollapseAllFolders(in page: any E2EPage) throws
    /// How many open folders the window's last collapse closed.
    func lastCollapsedCount(of page: any E2EPage) throws -> Int
}
