import Foundation

/// A window's sidebar after a relaunch: what `E2EStoreApp.relaunchSidebar(of:)` brought back.
@MainActor
struct E2ERelaunchedSidebar {
    /// The page of the tab the reopened window shows.
    var page: any E2EPage
    /// How many tabs, folders and splits the sidebar read back from its file holds.
    var itemCount: Int
    /// How many rows the reopened window's sidebar lists.
    var rowCount: Int
    /// How many of the reopened window's tabs loaded a page (the rest wait until they are selected).
    var loadedTabCount: Int
}

/// The sidebar store and tab creation as a test sees them: the saved sidebar behind a window, a relaunch of it, and
/// links from other apps.
@MainActor
protocol E2EStoreApp: E2EApp {
    /// How many tabs, folders and splits the sidebar of `page`'s window holds.
    func sidebarItemCount(of page: any E2EPage) throws -> Int
    /// Closes `page`'s window the way its close button does, then opens a new off-screen window on the same sidebar
    /// file read back from disk, the way the app does on launch, and returns what it brought back.
    func relaunchSidebar(of page: any E2EPage) async throws -> E2ERelaunchedSidebar
    /// Opens `url` the way a link clicked in another app arrives, and returns the page of the tab it opened.
    func openExternalLink(_ url: URL) throws -> any E2EPage
    /// The ID of the engine profile `page`'s tab was created in.
    func tabProfileID(of page: any E2EPage) throws -> String
}
