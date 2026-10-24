import Foundation

/// Profiles behind Spaces as a test reads them: the page a window shows after a Space changed profile, the app's
/// registered profiles and the renderer processes running. The Space menu itself goes through `E2ESpaceThemeApp`.
/// E2E/Harness/E2EAppAdapter+Profiles.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EProfilesApp: E2ESpaceThemeApp, E2EStoreApp, E2EWindowEdgesApp {
    /// The page of the tab `page`'s window shows now: `page` itself when it is the one shown, or else the shown tab,
    /// tracked for the test from now on (its earlier events are not seen). Nil while the window shows no page.
    func shownPage(besides page: any E2EPage) throws -> (any E2EPage)?
    /// The app's registered profiles in order, as "<id>:<name>".
    func registeredProfiles() throws -> [String]
    /// Every registered profile's storage UUID text by profile ID, as the app's registry holds them now (opening it
    /// if no one has yet).
    func registeredStoreIDs() throws -> [String: String]
    /// How many Chromium renderer processes the app runs now.
    func rendererProcessCount() throws -> Int
    /// Chooses the item at `path` (for example ["Move to Space", "Home"]) in the context menu of `page`'s tab row,
    /// as a click on it does. Throws when an item is missing or disabled.
    func chooseTabMenuItem(path: [String], of page: any E2EPage) throws
    /// The sidebar store ID of `page`'s tab, for `E2EStoreSeedApp.storeEntry(id:in:)`.
    func sidebarItemID(of page: any E2EPage) throws -> String
    /// The titles of the submenu at `path` in the Space menu of `page`'s window (for example ["Profile", "Delete
    /// Profile…"]), each with "!" when disabled.
    func spaceSubmenuTitles(_ path: [String], in page: any E2EPage) throws -> [String]
    /// Drops sidebar item `id` (an ID from `E2ESeededWindow.itemIDs`) at the end of the Favorites grid of `page`'s
    /// window through the grid's own drop, as releasing a drag there does. Returns whether the grid took it.
    func dropOnFavoritesGrid(item id: String, in page: any E2EPage) throws -> Bool
    /// Adds a persistent profile named `name` to the app's registry the way "New Profile…" does, without putting a
    /// Space on it, and returns its ID.
    func createRegisteredProfile(named name: String) throws -> String
    /// Runs the app's launch step that removes the folders of deleted profiles, with the profiles every window's
    /// Spaces show, and returns each pending folder's outcome as "<folder>:<outcome>".
    func deleteMarkedProfileFolders() throws -> [String]
}
