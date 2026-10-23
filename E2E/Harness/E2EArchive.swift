import Foundation

/// Auto-archive as a test sees it: a clock the test moves, a pass run as the timer runs it, the Today tabs and the
/// archive of a window's sidebar, and putting an item back. E2E/Harness/E2EAppAdapter+Archive.swift implements it;
/// every action but `resetArchive` is refused once the test has ended. IDs are sidebar item IDs, as
/// `E2ESeededWindow.itemIDs` gives them.
@MainActor
protocol E2EArchiveApp: E2EStoreSeedApp {
    /// Whether the archive pass timer is running.
    var archiverIsRunning: Bool { get }
    /// Gives auto-archive a clock that starts now and moves only with `advanceArchiveClock(by:)`. It also forgets
    /// every archive it opened, so the next pass reads each archive file afresh.
    func useManualArchiveClock() throws
    func advanceArchiveClock(by interval: TimeInterval) throws
    /// Runs one pass over every open window, as the timer does, and returns the IDs it archived.
    func runArchivePass() throws -> [String]
    /// The tabs in the Today section of the Space `page`'s window shows, in sidebar order, folders included.
    func archiveTodayTabs(besides page: any E2EPage) throws -> [String]
    /// The archived items of `page`'s window's sidebar, newest first.
    func archivedItems(besides page: any E2EPage) throws -> [String]
    /// Puts archived item `id` back, as the archive list's Reopen does. Returns whether it is back in the sidebar.
    func reopenArchived(_ id: String, besides page: any E2EPage) throws -> Bool
    /// The sidebar item of tab `page`.
    func archiveItem(of page: any E2EPage) throws -> String
    /// The sidebar item of the tab `page`'s window shows, nil when it shows none.
    func archiveShownItem(besides page: any E2EPage) throws -> String?
    /// The archive file of `page`'s window's sidebar.
    func archiveFile(besides page: any E2EPage) throws -> URL
    /// How many damaged records opening that archive file left out; nil when it could not be opened.
    func archiveSkippedRecords(besides page: any E2EPage) throws -> Int?
    /// Puts the real clock and the default thresholds back. Never refused, so a test can always clean up.
    func resetArchive()
}
