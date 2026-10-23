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

/// A notice about the sidebar the app showed, as the person reads it in its alert.
struct E2ESidebarNotice: Equatable {
    /// `cannotOpen`, `newerFile`, `setAside`, `missingProfile` or `windowSidebar`.
    var kind: String
    var message: String
    var detail: String
}

/// The app's sidebar stores a test opens windows on, with the sidebar file in `dataFolder` and window sidebars in
/// `windowFolder`. Every opening in one session asks the same stores, as the app asks its own stores again, and
/// every notice they show is kept, also one shown after a window opened (a save that failed).
@MainActor
final class E2ESidebarSession {
    let dataFolder: URL
    let windowFolder: URL
    /// Every notice the stores showed, in order.
    var notices: [E2ESidebarNotice] = []
    /// The stores, made by the app adapter on the first opening.
    var stores: AnyObject?

    init(dataFolder: URL, windowFolder: URL) {
        self.dataFolder = dataFolder
        self.windowFolder = windowFolder
    }
}

/// What opening a window on a saved sidebar did: `E2EStoreApp.openSavedSidebar(...)`.
@MainActor
struct E2ESidebarOpening {
    /// The page of the window's shown tab; nil when no window opened, or it opened without a tab (it is closed).
    var page: (any E2EPage)?
    /// Whether a window opened.
    var opened: Bool
    /// The notices shown while opening, in order: on the window, or in place of it.
    var notices: [E2ESidebarNotice]
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
    /// Opens a window the way the app opens one on its saved sidebar, opening `url`, on `session`'s stores (the
    /// sidebar file is read on the first opening that gets it, and again after a refusal). With `ownSidebar` the
    /// window gets a sidebar of its own on the app's default profile instead, as a smoke window does. Notices are
    /// recorded in the session, never shown.
    func openSavedSidebar(in session: E2ESidebarSession, url: URL, ownSidebar: Bool) async throws -> E2ESidebarOpening
    /// Hands the app `url` the way the system delivers a link clicked in another app.
    func deliverLinkFromOtherApp(_ url: URL) throws
    /// The sidebar notices the app showed outside `openSavedSidebar`, since the run started.
    var appSidebarNotices: [E2ESidebarNotice] { get }
}
