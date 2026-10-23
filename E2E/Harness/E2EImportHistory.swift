import Foundation

/// What the Arc import's history step did with files (`E2EImportHistoryApp.importFileLog()`), read from the log the
/// step keeps.
struct E2EImportFileLog: Equatable, CustomStringConvertible {
    /// The files in the chosen folder that were read or copied, in order, relative to the folder ("Default/History").
    var originals: [String]
    /// How many times SQLite opened a database, and whether every one was a copy in the app's temporary folder.
    var openedCount: Int
    var openedOnlyCopies: Bool
    /// Whether every temporary folder the step made is gone again.
    var copiesRemoved: Bool

    var description: String {
        "originals=\(originals) opened=\(openedCount) only_copies=\(openedOnlyCopies) removed=\(copiesRemoved)"
    }
}

/// The history and bookmarks step of the Arc import wizard as a test drives it, on top of `E2EImportApp`: the folder
/// picker is answered with a User Data folder built from a fixture, and the test reads the file log and the
/// histories the visits went into.
@MainActor
protocol E2EImportHistoryApp: E2EImportApp, E2EHistoryApp {
    /// Builds a User Data folder from the fixture folder `name` under E2E/Fixtures/import/ in a new temporary folder
    /// (each profile's `History.sql` becomes its `History` database, and the script is deleted), and makes the
    /// wizard's folder picker answer with it from now on. Nil stops answering (the picker answers "cancelled").
    /// Returns the folder. The folder is deleted by `useImportFolder(nil)` and when the next one is built.
    @discardableResult
    func useImportFolder(_ name: String?) throws -> URL?
    /// How many times the wizard asked the folder picker since the folder was set.
    func importFolderRequests() throws -> Int
    /// The files the last history read touched, relative to `folder`; nil when no history read ran.
    func importFileLog(relativeTo folder: URL) throws -> E2EImportFileLog?
    /// The history of Bow's default profile, oldest visit first; empty when it recorded nothing.
    func defaultProfileHistory() throws -> [E2EHistoryEntry]
    /// The pinned section of the Space on screen in `page`'s window, as "depth:title" rows, depth first.
    func pinnedRows(in page: any E2EPage) throws -> [String]
}
