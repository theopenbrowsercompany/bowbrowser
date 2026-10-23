import Foundation

/// One row of the archive popover as a test reads it.
struct E2EArchivePopoverRow: Equatable {
    /// The archived item's sidebar item ID.
    let item: String
    let title: String
    /// The line under the title: the source Space and when it was archived.
    let detail: String
}

/// The sidebar footer's archive button and the popover it opens, as a test sees them. E2E/Harness/E2EAppAdapter+ArchivePopover.swift
/// implements it; every action is refused once the test has ended.
@MainActor
protocol E2EArchivePopoverApp: E2EArchiveApp {
    /// Clicks the archive button in the footer of the window `page` is in (it closes the popover when it is open).
    func clickArchiveButton(in page: any E2EPage) throws
    /// Whether that window's archive popover is showing.
    func archivePopoverIsShown(in page: any E2EPage) throws -> Bool
    /// The rows the popover lists, top first; throws when it is not showing.
    func archivePopoverRows(in page: any E2EPage) throws -> [E2EArchivePopoverRow]
    /// Whether the popover shows its "No archived tabs" text.
    func archivePopoverShowsEmptyState(in page: any E2EPage) throws -> Bool
    /// Clicks the row of archived item `item`, as a person's click does.
    func clickArchivePopoverRow(_ item: String, in page: any E2EPage) throws
    /// The popover's threshold menu: its titles in order and the one chosen.
    func archiveThresholdMenu(in page: any E2EPage) throws -> (titles: [String], selected: String)
    /// Chooses `title` in the threshold menu, as picking it from the menu does.
    func chooseArchiveThreshold(_ title: String, in page: any E2EPage) throws
    /// The threshold saved for the profile of the Space `page`'s window shows.
    func archiveSavedThreshold(besides page: any E2EPage) throws -> String
    /// Closes the popover when it is open. Never refused, so a test can always clean up.
    func closeArchivePopover(in page: any E2EPage)
}
