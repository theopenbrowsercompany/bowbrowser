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

/// Reads the `urls` and `visits` tables of a Chromium `History` database.
public enum ChromiumHistory {
    public static let fileName = "History"

    /// Copies the database (and its WAL and journal files) into a temporary folder and reads the copy read only,
    /// so a running browser's lock never matters and the original is never touched.
    /// - Parameter webOnly: drop visits whose URL is not http or https (`chrome://`, `file:`, `about:`).
    public static func load(profileFolder: URL, webOnly: Bool = true) throws -> [ChromiumVisit] {
        let source = profileFolder.appendingPathComponent(fileName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw ChromiumImportError.missingFile(fileName)
        }
        let temp = fm.temporaryDirectory.appendingPathComponent("bow-history-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-journal"] {
                let from = URL(fileURLWithPath: source.path + suffix)
                if fm.fileExists(atPath: from.path) {
                    try fm.copyItem(at: from, to: temp.appendingPathComponent(fileName + suffix))
                }
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw ChromiumImportError.database(
                file: fileName, reason: "could not copy it: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: temp) }
        return try read(database: temp.appendingPathComponent(fileName), webOnly: webOnly)
    }

    /// Reads a database file in place, read only. Use `load` for a live profile; this is for a file already copied.
    public static func read(database: URL, webOnly: Bool = true) throws -> [ChromiumVisit] {
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
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw ChromiumImportError.database(file: fileName, reason: String(cString: sqlite3_errmsg(db)))
            }
            guard let urlText = sqlite3_column_text(stmt, 0) else { continue }
            let url = String(cString: urlText)
            if webOnly && !isWeb(url) { continue }
            guard let date = ChromiumTime.date(microseconds: sqlite3_column_int64(stmt, 2)) else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let transition = Int(sqlite3_column_int64(stmt, 3) & 0xFF)
            visits.append(ChromiumVisit(url: url, title: title, date: date, transition: transition))
        }
        return visits
    }

    private static func isWeb(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }
}
