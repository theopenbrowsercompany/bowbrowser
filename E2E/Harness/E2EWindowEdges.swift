import Foundation

/// The window's edges as a test sees them: Spaces on other profiles in one window, sidebar changes made the way a
/// feature makes them (pin, delete a Space, insert a saved tab), the empty state, window close requests and the saved
/// sidebar file. E2E/Harness/E2EAppAdapter+WindowEdges.swift implements it; every action is refused once the test
/// has ended.
@MainActor
protocol E2EWindowEdgesApp: E2EApp {
    /// Creates a Space on profile `profileID` (the engine profile of that ID, which may not exist) in `page`'s
    /// window, switches to it, and returns its ID.
    func createSpace(besides page: any E2EPage, profileID: String) throws -> String
    /// The engine profile ID of `page`'s tab, for a second Space on the same profile.
    func profileID(of page: any E2EPage) throws -> String
    /// Adds a saved tab on `url` to the today section of the Space on screen, after the active tab, without loading
    /// it (as a relaunch brings tabs back), and returns its sidebar item ID.
    func insertSavedTab(_ url: URL, besides page: any E2EPage, title: String) throws -> String
    /// Selects saved tab `item` of `page`'s window the way clicking its row does.
    func selectSavedTab(_ item: String, besides page: any E2EPage) throws
    /// Switches `page`'s window to Space `space`.
    func switchToSpace(_ space: String, besides page: any E2EPage) throws
    /// The ID of the Space on screen in `page`'s window.
    func activeSpace(besides page: any E2EPage) throws -> String
    /// Deletes Space `space` of `page`'s window with every tab in it.
    func deleteSpace(_ space: String, besides page: any E2EPage) throws
    /// Pins `page`'s tab.
    func pin(_ page: any E2EPage) throws
    /// Asks `page`'s window to close, the way its close button does, without waiting for it to close.
    func requestWindowClose(of page: any E2EPage) throws
    /// Whether `page` and `other` are in the same window.
    func sameWindow(_ page: any E2EPage, _ other: any E2EPage) throws -> Bool
    /// Clicks the empty state's Load Tab button in `page`'s window.
    func clickLoadTab(besides page: any E2EPage) throws
    /// The window `page` is in, as the checks read it.
    func windowState(of page: any E2EPage) throws -> E2EWindowState
    /// The sidebar file of `page`'s window as it is on disk now.
    func sidebarFile(of page: any E2EPage) throws -> String
    /// When the sidebar file of `page`'s window was last written, nil while there is none.
    func sidebarFileModified(of page: any E2EPage) throws -> Date?
    /// How long a window waits after the last page it recorded before writing the sidebar file.
    var recordSaveDelay: TimeInterval { get }
}

/// A window as the edge checks read it.
struct E2EWindowState {
    var isOpen: Bool
    /// Rows the window lists for the Space on screen.
    var rowCount: Int
    /// Of those, the tabs whose page is loaded.
    var loadedCount: Int
    var activeItem: String?
    /// True while the page area shows a page.
    var showsPage: Bool
    /// True while the empty state (a Space with no tabs, or an active tab with no page) covers the page area.
    var showsEmptyState: Bool
    /// True when the empty state stands for an active tab with no page rather than an empty Space.
    var showsUnloadedTab: Bool
    /// The title the active row shows.
    var activeTitle: String
}
