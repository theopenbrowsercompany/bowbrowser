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

    /// The side files SQLite may keep beside a database, copied with it so committed changes they hold come along.
    /// The `-shm` index is not copied: SQLite rebuilds it from the `-wal` file.
    static let sideFileSuffixes = ["-wal", "-journal"]

    /// Reads the profile's History from a copy. See `loadReport`.
    public static func load(profileFolder: URL, webOnly: Bool = true) throws -> [ChromiumVisit] {
        try loadReport(profileFolder: profileFolder, webOnly: webOnly).visits
    }

    /// Copies `History` (and its `-wal` and `-journal` files when they are there) byte for byte into a new folder
    /// inside `temporaryFolder`, lets SQLite settle the copy (a committed `-wal` is folded in, a hot journal rolled
    /// back, both in the copy), then reads the copy read only. The original is only ever copied: SQLite never opens
    /// it, so nothing in the person's folder can change, not even a lock or index file. The copy is deleted before
    /// this returns or throws.
    /// - Parameters:
    ///   - webOnly: drop visits whose URL is not http or https (`chrome://`, `file:`, `about:`).
    ///   - temporaryFolder: where the copy's folder is made; the system's temporary folder when nil.
    ///   - log: records the files copied, opened and removed.
    public static func loadReport(
        profileFolder: URL, webOnly: Bool = true, temporaryFolder: URL? = nil, log: ChromiumFileLog? = nil
    ) throws -> ChromiumHistoryReport {
        let source = profileFolder.appendingPathComponent(fileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw ChromiumImportError.missingFile(fileName)
        }
        let parent = temporaryFolder ?? fm.temporaryDirectory
        let temp = parent.appendingPathComponent("bow-history-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            throw ChromiumImportError.database(
                file: fileName, reason: "could not make a temporary folder: \(error.localizedDescription)")
        }
        defer {
            try? fm.removeItem(at: temp)
            log?.record(.removed(temp))
        }
        let copy = temp.appendingPathComponent(fileName)
        for suffix in [""] + sideFileSuffixes {
            let from = profileFolder.appendingPathComponent(fileName + suffix)
            guard suffix.isEmpty || fm.fileExists(atPath: from.path) else { continue }
            let to = temp.appendingPathComponent(fileName + suffix)
            log?.record(.copied(from: from, to: to))
            do {
                try fm.copyItem(at: from, to: to)
            } catch {
                throw ChromiumImportError.database(
                    file: fileName + suffix, reason: "it could not be copied (\(error.localizedDescription))")
            }
        }
        try settle(copy, log: log)
        return try read(database: copy, webOnly: webOnly, log: log)
    }

    /// Opens the copy read and write once, so SQLite folds a copied `-wal` into it or rolls back a copied hot journal,
    /// and switches it to a plain journal, so the read only open that follows needs no side files.
    private static func settle(_ copy: URL, log: ChromiumFileLog?) throws {
        log?.record(.opened(copy))
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw ChromiumImportError.database(file: fileName, reason: reason)
        }
        defer { sqlite3_close(db) }
        // A file that is not a database fails here, with "file is not a database".
        guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw ChromiumImportError.database(file: fileName, reason: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Reads a database file in place, read only. Use `loadReport` for a live profile; this is for a file already
    /// copied.
    public static func read(database: URL, webOnly: Bool = true, log: ChromiumFileLog? = nil) throws
        -> ChromiumHistoryReport
    {
        log?.record(.opened(database))
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
