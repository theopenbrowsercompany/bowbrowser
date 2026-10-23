import Foundation
import SQLite3

/// One visit read from a Chromium `History` database. A neutral shape: an adapter maps it into the history store.
public struct ChromiumVisit: Equatable, Sendable {
    public let url: String
    /// The page title Chromium last saw for the URL, which may be empty.
    public let title: String
    public let date: Date
    /// Chromium's core transition type (the low byte of `visits.transition`): 0 link, 1 typed, 2 auto bookmark, and so on.
    public let transition: Int
    /// Whether the person typed the address.
    public var isTyped: Bool { transition == 1 }

    public init(url: String, title: String, date: Date, transition: Int) {
        self.url = url
        self.title = title
        self.date = date
        self.transition = transition
    }
}

/// What a History read produced: the visits, and how many rows were left out because their time was unusable.
public struct ChromiumHistoryReport: Equatable, Sendable {
    public let visits: [ChromiumVisit]
    /// Visits whose `visit_time` was zero or negative, so no date could be given.
    public let undatedCount: Int
}

/// Reads the `urls` and `visits` tables of a Chromium `History` database.
public enum ChromiumHistory {
    public static let fileName = "History"

    /// Reads a consistent snapshot of the profile's History. See `loadReport`.
    public static func load(profileFolder: URL, webOnly: Bool = true) throws -> [ChromiumVisit] {
        try loadReport(profileFolder: profileFolder, webOnly: webOnly).visits
    }

    /// Opens the original read only, copies it with SQLite's online backup API into a temporary database, and reads
    /// that copy. The backup sees one consistent state even while a browser is writing (WAL frames included), and
    /// the copy is disposable, so SQLite may recover a hot journal in it. The original is never written to.
    /// - Parameter webOnly: drop visits whose URL is not http or https (`chrome://`, `file:`, `about:`).
    public static func loadReport(profileFolder: URL, webOnly: Bool = true) throws -> ChromiumHistoryReport {
        let source = profileFolder.appendingPathComponent(fileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw ChromiumImportError.missingFile(fileName)
        }
        let temp = fm.temporaryDirectory.appendingPathComponent("bow-history-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            throw ChromiumImportError.database(
                file: fileName, reason: "could not make a temporary folder: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: temp) }
        let snapshot = temp.appendingPathComponent(fileName)
        try backup(from: source, to: snapshot)
        return try read(database: snapshot, webOnly: webOnly)
    }

    private static func backup(from source: URL, to destination: URL) throws {
        func fail(_ db: OpaquePointer?, _ fallback: String) -> ChromiumImportError {
            .database(file: fileName, reason: db.map { String(cString: sqlite3_errmsg($0)) } ?? fallback)
        }
        var sourceHandle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let error = fail(sourceHandle, "unknown error")
            sqlite3_close(sourceHandle)
            throw error
        }
        defer { sqlite3_close(sourceHandle) }
        var destinationHandle: OpaquePointer?
        guard
            sqlite3_open_v2(
                destination.path, &destinationHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else {
            let error = fail(destinationHandle, "unknown error")
            sqlite3_close(destinationHandle)
            throw error
        }
        defer { sqlite3_close(destinationHandle) }
        // Retry while a writer holds the database busy, for up to a few seconds.
        sqlite3_busy_timeout(sourceHandle, 3000)
        guard let backup = sqlite3_backup_init(destinationHandle, "main", sourceHandle, "main") else {
            throw fail(destinationHandle, "could not start the copy")
        }
        let result = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else {
            // A file that is not a database fails here, with "file is not a database".
            throw ChromiumImportError.database(file: fileName, reason: String(cString: sqlite3_errstr(result)))
        }
        // The backup keeps the source's WAL flag; the snapshot is read later without side files, so turn it off.
        guard sqlite3_exec(destinationHandle, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw fail(destinationHandle, "could not finish the copy")
        }
    }

    /// Reads a database file in place, read only. Use `load` for a live profile; this is for a file already copied.
    public static func read(database: URL, webOnly: Bool = true) throws -> ChromiumHistoryReport {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw ChromiumImportError.database(file: fileName, reason: reason)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT urls.url, urls.title, visits.visit_time, visits.transition
            FROM visits JOIN urls ON urls.id = visits.url
            ORDER BY visits.visit_time ASC, visits.id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            // A file that is not a database fails here too, with "file is not a database".
            let reason = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(statement)
            throw ChromiumImportError.database(file: fileName, reason: reason)
        }
        defer { sqlite3_finalize(stmt) }

        var visits: [ChromiumVisit] = []
        var undated = 0
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw ChromiumImportError.database(file: fileName, reason: String(cString: sqlite3_errmsg(db)))
            }
            guard let urlText = sqlite3_column_text(stmt, 0) else { continue }
            let url = String(cString: urlText)
            if webOnly && !isWeb(url) { continue }
            guard let date = ChromiumTime.date(microseconds: sqlite3_column_int64(stmt, 2)) else {
                undated += 1
                continue
            }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let transition = Int(sqlite3_column_int64(stmt, 3) & 0xFF)
            // Subframe loads (ads, embeds) are not pages the person visited.
            if transition == 3 || transition == 4 { continue }
            visits.append(ChromiumVisit(url: url, title: title, date: date, transition: transition))
        }
        return ChromiumHistoryReport(visits: visits, undatedCount: undated)
    }

    private static func isWeb(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }
}
