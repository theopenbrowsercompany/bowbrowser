import Foundation

/// One tab's row in a window's sidebar, as the sidebar draws it.
struct E2ESidebarRow: Equatable, CustomStringConvertible {
    var title: String
    /// True while the row shows its loading spinner.
    var isLoading: Bool
    /// True while the row shows the site's own icon rather than the placeholder.
    var hasFavicon: Bool
    /// True while the row is highlighted as the active tab.
    var isActive: Bool
    /// True when the title ends before the close button's place, laid out at the row's width.
    var titleClearsClose = true

    var description: String {
        "\(title)\(isActive ? "*" : "")\(isLoading ? " loading" : "")\(hasFavicon ? " icon" : "")\(titleClearsClose ? "" : " under-close")"
    }
}

/// The sidebar and tab commands of the app as a test sees them. Each action goes through the control a person
/// uses (the row, its close button, the New Tab button, the menu item) and lands where a click would.
@MainActor
protocol E2ESidebarApp: E2EApp {
    /// The sidebar rows of the window `page` is in, top to bottom.
    func sidebarRows(of page: any E2EPage) throws -> [E2ESidebarRow]
    /// The row of `page`'s tab each time its page reported a state change (title, icon, loading), read right
    /// after the window handled the change.
    func sidebarRowHistory(of page: any E2EPage) -> [E2ESidebarRow]
    /// Clicks the sidebar row of `page`'s tab.
    func clickSidebarRow(of page: any E2EPage) throws
    /// Clicks the close button on the sidebar row of `page`'s tab; throws when the button is not showing.
    func clickSidebarClose(of page: any E2EPage) throws
    /// Clicks the sidebar's New Tab button in the window `page` is in, with the window set to open `url` in new
    /// tabs, and returns the new tab's page.
    func clickNewTab(besides page: any E2EPage, opening url: URL) throws -> any E2EPage
    /// Chooses the menu item whose shortcut is Command with `key` (for example "w" for Close Tab), sent to the
    /// window `page` is in, as the shortcut does when that window is key. Throws when no menu item has it.
    func chooseMenuItem(commandKey key: String, in page: any E2EPage) throws
    /// Moves `page`'s tab to `index` in its window's tab order, as dropping its row there does.
    func moveTab(_ page: any E2EPage, to index: Int) throws
}

/// One row of the sidebar outline (`E2EZonesApp.sidebarOutlineRows(of:)`): its text and its depth.
struct E2EOutlineRow: Equatable, CustomStringConvertible {
    var title: String
    var level: Int

    /// The title after one ">" per level: "pinned", ">Docs", ">>P1".
    var description: String { String(repeating: ">", count: level) + title }
}

/// The sidebar's zones as a test sees them: Favorites, pinned and today, with a divider between pinned and today.
@MainActor
protocol E2EZonesApp: E2ESidebarApp {
    /// The rows of the sidebar outline of `page`'s window, top to bottom: each section's header as its zone
    /// ("favorites", "pinned", "today") or "divider", and each item as its title.
    func sidebarOutline(of page: any E2EPage) throws -> [String]
    /// The same rows as `sidebarOutline(of:)` with each row's depth in the outline, so nesting shows: a section
    /// header is at level 0, an item directly in a section at 1, and an item inside a folder one deeper than the
    /// folder.
    func sidebarOutlineRows(of page: any E2EPage) throws -> [E2EOutlineRow]
    /// The zone ("favorites", "pinned" or "today") `page`'s tab is listed in, nil when it is in none.
    func sidebarZone(of page: any E2EPage) throws -> String?
    /// Drags `page`'s tab onto the outline as a person does: onto row `row` of `sidebarOutline(of:)` (nil for
    /// between sections) at child `childIndex` among that row's items (counted before the tab leaves its place; -1
    /// drops on the row itself). The drop goes through the outline's own routing, so a drop on a tab lands above it
    /// and a drop on the divider at the top of today. Throws when the sidebar refuses the drop.
    func dragTab(_ page: any E2EPage, onRow row: Int?, childIndex: Int) throws
}
