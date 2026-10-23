import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Browsing history for one profile, kept in SQLite.
///
/// Persistent profiles write `history.sqlite` under their own folder; an ephemeral profile uses an
/// in memory database, so nothing reaches the disk. Feed it with `handle(_:at:)` from the tab's
/// events, then read it with `recent`, `search` and `visits`. Calls are safe from any thread.
public final class HistoryStore: @unchecked Sendable {
    public let profileID: ProfileID
    public let isPersistent: Bool
    /// The database file, nil for an ephemeral profile.
    public let fileURL: URL?

    private let lock = NSLock()
    private var db: OpaquePointer?
    /// Titles that arrived before their page's commit, applied when the commit lands.
    private var pendingTitles: [String: String] = [:]

    /// Opens the history of `profileID`. Persistent history lives in
    /// `<directory>/<profile>/history.sqlite`; the folder is created when missing.
    public init(profileID: ProfileID, isPersistent: Bool, directory: URL) throws {
        self.profileID = profileID
        self.isPersistent = isPersistent
        var handle: OpaquePointer?
        if isPersistent {
            // Lowercase hex of the name: unambiguous, and safe on case insensitive volumes.
            let name = "p" + profileID.rawValue.utf8.map { String(format: "%02x", $0) }.joined()
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("history.sqlite")
            fileURL = file
            let code = sqlite3_open(file.path, &handle)
            if code != SQLITE_OK {
                let error = Self.error(code, handle)
                sqlite3_close(handle)
                throw error
            }
        } else {
            fileURL = nil
            let code = sqlite3_open(":memory:", &handle)
            if code != SQLITE_OK {
                let error = Self.error(code, handle)
                sqlite3_close(handle)
                throw error
            }
        }
        db = handle
        do {
            sqlite3_busy_timeout(handle, 5000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA secure_delete = ON")
            if isPersistent { try execute("PRAGMA journal_mode = WAL") }
            try migrate()
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Recording

    /// Whether visits to this URL are kept: web pages and local files only, never internal pages.
    public static func isRecordable(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false
        case "file": return true
        default: return false
        }
    }

    /// Feeds one tab event. A commit records a visit (reloads and back or forward moves do not
    /// count as new visits); a state change with a title names the page it describes.
    public func handle(_ event: TabEvent, at date: Date = Date()) throws {
        switch event {
        case .didCommit(let navigation):
            switch navigation.transition {
            case .reload, .backForward: return
            default:
                try recordVisit(
                    url: navigation.url, title: takePendingTitle(for: navigation.url),
                    transition: navigation.transition, at: date)
            }
        case .stateChanged(let state):
            if let url = state.url, !state.title.isEmpty { try setTitle(state.title, for: url) }
        default:
            return
        }
    }

    public func recordVisit(
        url: URL, title: String = "", transition: NavigationTransition = .link, at date: Date = Date()
    ) throws {
        guard Self.isRecordable(url) else { return }
        let key = Self.key(url)
        let time = date.timeIntervalSince1970
        let typed = transition == .typed ? 1 : 0
        try locked {
            try transaction {
                try run(
                    """
                    INSERT INTO places (url, title, visit_count, typed_count, last_visit, search_text)
                    VALUES (?1, ?2, 1, ?3, ?4, ?5)
                    ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, typed_count = typed_count + ?3,
                        last_visit = MAX(last_visit, ?4),
                        title = CASE WHEN ?2 = '' THEN title ELSE ?2 END,
                        search_text = CASE WHEN ?2 = '' THEN search_text ELSE ?5 END
                    """,
                    [.text(key), .text(title), .int(typed), .double(time), .text(Self.searchText(key, title))])
                try run(
                    "INSERT INTO visits (place_id, time, transition) VALUES ((SELECT id FROM places WHERE url = ?1), ?2, ?3)",
                    [.text(key), .double(time), .text(Self.name(of: transition))])
            }
        }
    }

    /// How many imported visits go into one transaction. The store's lock is let go between chunks, so a page load or
    /// a search on the same profile waits for one chunk at most, never for a whole imported profile.
    public static let importChunkSize = 500

    /// Adds visits brought in from another browser, `chunkSize` visits per transaction, and returns what it added so
    /// `removeImported(_:)` can take exactly that out again, all chunks together.
    ///
    /// The lock is held for one chunk at a time, and `afterChunk` is called after each committed chunk with the lock
    /// let go and the number of visits handled so far. When a chunk fails, what the earlier chunks added is taken out
    /// again before the error is thrown, so a failed import leaves history as it was.
    ///
    /// A visit is left out when its URL is not recordable, or when the page already has a visit at the very same time
    /// (the same visit imported before, or earlier in this import), so importing the same history twice adds nothing
    /// the second time. An imported title names a page only when it has no title yet, so a title seen live is never
    /// replaced.
    public func importVisits(
        _ visits: [HistoryImportVisit], chunkSize: Int = importChunkSize, afterChunk: ((Int) -> Void)? = nil
    ) throws -> HistoryImportRecord {
        var record = HistoryImportRecord()
        let size = max(1, chunkSize)
        var start = 0
        while start < visits.count {
            let end = min(start + size, visits.count)
            do {
                try locked {
                    try transaction { try importChunk(visits[start..<end], into: &record) }
                }
            } catch {
                // The chunk itself was rolled back; take out what the committed chunks added.
                _ = try? removeImported(record)
                throw error
            }
            start = end
            afterChunk?(end)
        }
        return record
    }

    /// Adds one chunk of imported visits inside the caller's lock and transaction, its statements prepared once.
    private func importChunk(_ visits: ArraySlice<HistoryImportVisit>, into record: inout HistoryImportRecord) throws {
        let known = try Statement(
            db,
            """
            SELECT 1 FROM visits JOIN places ON places.id = visits.place_id
            WHERE places.url = ?1 AND visits.time = ?2 LIMIT 1
            """)
        let place = try Statement(
            db,
            """
            INSERT INTO places (url, title, visit_count, typed_count, last_visit, search_text)
            VALUES (?1, ?2, 1, ?3, ?4, ?5)
            ON CONFLICT(url) DO UPDATE SET visit_count = visit_count + 1, typed_count = typed_count + ?3,
                last_visit = MAX(last_visit, ?4),
                title = CASE WHEN title = '' THEN ?2 ELSE title END,
                search_text = CASE WHEN title = '' AND ?2 <> '' THEN ?5 ELSE search_text END
            """)
        let visitRow = try Statement(
            db,
            "INSERT INTO visits (place_id, time, transition) VALUES ((SELECT id FROM places WHERE url = ?1), ?2, ?3)")
        for visit in visits {
            guard Self.isRecordable(visit.url) else {
                record.skippedCount += 1
                continue
            }
            let key = Self.key(visit.url)
            let time = visit.time.timeIntervalSince1970
            if try known.step([.text(key), .double(time)]) {
                record.skippedCount += 1
                continue
            }
            let typed = visit.transition == .typed ? 1 : 0
            _ = try place.step([
                .text(key), .text(visit.title), .int(typed), .double(time), .text(Self.searchText(key, visit.title)),
            ])
            _ = try visitRow.step([.text(key), .double(time), .text(Self.name(of: visit.transition))])
            record.visits.append(.init(id: sqlite3_last_insert_rowid(db), time: time))
        }
    }

    /// Takes out the visits `importVisits(_:)` added, and nothing else: a visit counts as the import's only while
    /// both its row ID and its time match, so a visit recorded since (even one that reused a deleted row's ID) stays.
    /// Pages keep their other visits, with counts and last visit recomputed; a page left with none disappears.
    /// Visits already deleted are skipped. Returns how many visits were taken out.
    @discardableResult
    public func removeImported(_ record: HistoryImportRecord) throws -> Int {
        guard !record.visits.isEmpty else { return 0 }
        return try locked {
            var removed = 0
            try transaction {
                try execute("CREATE TEMP TABLE IF NOT EXISTS imported_visits (id INTEGER NOT NULL, time REAL NOT NULL)")
                try execute("DELETE FROM imported_visits")
                for visit in record.visits {
                    try run(
                        "INSERT INTO imported_visits (id, time) VALUES (?1, ?2)",
                        [.int(Int(visit.id)), .double(visit.time)])
                }
                let matching =
                    "SELECT visits.id FROM visits JOIN imported_visits ON imported_visits.id = visits.id "
                    + "AND imported_visits.time = visits.time"
                try run(
                    "UPDATE places SET last_visit = -1 WHERE id IN (SELECT place_id FROM visits WHERE id IN (\(matching)))",
                    [])
                try run("DELETE FROM visits WHERE id IN (\(matching))", [])
                removed = Int(sqlite3_changes(db))
                try run("DELETE FROM places WHERE last_visit = -1 AND id NOT IN (SELECT place_id FROM visits)", [])
                try run(
                    """
                    UPDATE places SET
                        visit_count = (SELECT COUNT(*) FROM visits WHERE place_id = places.id),
                        typed_count = (SELECT COUNT(*) FROM visits WHERE place_id = places.id AND transition = 'typed'),
                        last_visit = (SELECT MAX(time) FROM visits WHERE place_id = places.id)
                    WHERE last_visit = -1
                    """, [])
                try execute("DROP TABLE imported_visits")
            }
            return removed
        }
    }

    /// The number of visits, to every page.
    public func visitCount() throws -> Int {
        try locked { try rows("SELECT COUNT(*) FROM visits", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    /// Updates the title of a page that is already in history; unknown pages are ignored.
    public func setTitle(_ title: String, for url: URL) throws {
        guard Self.isRecordable(url), !title.isEmpty else { return }
        let key = Self.key(url)
        try locked {
            try run(
                "UPDATE places SET title = ?1, search_text = ?3 WHERE url = ?2",
                [.text(title), .text(key), .text(Self.searchText(key, title))])
            if sqlite3_changes(db) == 0 {
                if pendingTitles.count >= 64 { pendingTitles.removeAll() }
                pendingTitles[key] = title
            }
        }
    }

    private func takePendingTitle(for url: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        return pendingTitles.removeValue(forKey: Self.key(url)) ?? ""
    }

    private static func searchText(_ key: String, _ title: String) -> String {
        (key + " " + title).lowercased()
    }

    // MARK: Querying

    /// The most recently visited pages, newest first.
    public func recent(limit: Int = 50) throws -> [HistoryEntry] {
        try locked {
            try rows(
                "\(Self.selectEntry) ORDER BY last_visit DESC, id DESC LIMIT ?1", [.int(max(0, limit))], Self.entry)
        }
    }

    /// Pages whose URL or title contains every word of `text` (case insensitive), best first:
    /// more visits, typed visits counting double, then most recent. Blank text returns nothing.
    public func search(_ text: String, limit: Int = 20) throws -> [HistoryEntry] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var args: [Binding] = []
        var clauses: [String] = []
        for word in words.map({ $0.lowercased() }) {
            let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            args.append(.text("%" + escaped + "%"))
            clauses.append("search_text LIKE ?\(args.count) ESCAPE '\\'")
        }
        args.append(.int(max(0, limit)))
        let sql =
            "\(Self.selectEntry) WHERE \(clauses.joined(separator: " AND ")) "
            + "ORDER BY (visit_count + typed_count) DESC, last_visit DESC, id DESC LIMIT ?\(args.count)"
        return try locked { try rows(sql, args, Self.entry) }
    }

    /// The entry for one page, or nil when it was never visited.
    public func entry(for url: URL) throws -> HistoryEntry? {
        try locked { try rows("\(Self.selectEntry) WHERE url = ?1", [.text(Self.key(url))], Self.entry).first }
    }

    /// Every visit to one page, newest first.
    public func visits(for url: URL) throws -> [HistoryVisit] {
        try locked {
            try rows(
                """
                SELECT visits.time, visits.transition FROM visits JOIN places ON places.id = visits.place_id
                WHERE places.url = ?1 ORDER BY visits.time DESC, visits.id DESC
                """,
                [.text(Self.key(url))]
            ) { stmt in
                HistoryVisit(
                    time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    transition: Self.transition(named: Self.text(stmt, 1)))
            }
        }
    }

    /// The number of distinct pages.
    public func count() throws -> Int {
        try locked { try rows("SELECT COUNT(*) FROM places", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    }

    // MARK: Deleting

    /// Forgets one page and all its visits.
    public func delete(url: URL) throws {
        try locked { try run("DELETE FROM places WHERE url = ?1", [.text(Self.key(url))]) }
    }

    /// Forgets every visit in `range`. A page keeps its remaining visits, with counts and last
    /// visit adjusted; a page left with none disappears.
    public func delete(visitsIn range: ClosedRange<Date>) throws {
        let lower = range.lowerBound.timeIntervalSince1970
        let upper = range.upperBound.timeIntervalSince1970
        try locked {
            try transaction {
                // Mark the pages that lose visits (last_visit -1), so only they are recounted.
                try run(
                    "UPDATE places SET last_visit = -1 WHERE id IN (SELECT place_id FROM visits WHERE time >= ?1 AND time <= ?2)",
                    [.double(lower), .double(upper)])
                try run("DELETE FROM visits WHERE time >= ?1 AND time <= ?2", [.double(lower), .double(upper)])
                try run("DELETE FROM places WHERE last_visit = -1 AND id NOT IN (SELECT place_id FROM visits)", [])
                try run(
                    """
                    UPDATE places SET
                        visit_count = (SELECT COUNT(*) FROM visits WHERE place_id = places.id),
                        typed_count = (SELECT COUNT(*) FROM visits WHERE place_id = places.id AND transition = 'typed'),
                        last_visit = (SELECT MAX(time) FROM visits WHERE place_id = places.id)
                    WHERE last_visit = -1
                    """, [])
            }
        }
    }

    public func deleteAll() throws {
        try locked { try run("DELETE FROM places", []) }
    }

    // MARK: SQLite plumbing

    private enum Binding {
        case text(String)
        case int(Int)
        case double(Double)
    }

    private static let selectEntry =
        "SELECT url, title, visit_count, typed_count, last_visit FROM places"

    private static func entry(_ stmt: OpaquePointer) -> HistoryEntry? {
        guard let url = URL(string: text(stmt, 0)) else { return nil }
        return HistoryEntry(
            url: url, title: text(stmt, 1), visitCount: Int(sqlite3_column_int64(stmt, 2)),
            typedCount: Int(sqlite3_column_int64(stmt, 3)),
            lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(stmt, column) else { return "" }
        let count = Int(sqlite3_column_bytes(stmt, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    /// The fragment is not part of what a person visited: `/a#x` and `/a#y` are one page.
    private static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.host != nil, parts.path.isEmpty { parts.path = "/" }
        return parts.string ?? url.absoluteString
    }

    private static func name(of transition: NavigationTransition) -> String {
        switch transition {
        case .link: "link"
        case .typed: "typed"
        case .formSubmit: "formSubmit"
        case .reload: "reload"
        case .backForward: "backForward"
        case .other: "other"
        }
    }

    private static func transition(named name: String) -> NavigationTransition {
        switch name {
        case "link": .link
        case "typed": .typed
        case "formSubmit": .formSubmit
        case "reload": .reload
        case "backForward": .backForward
        default: .other
        }
    }

    private static let schemaVersion = 1

    private func migrate() throws {
        let version = try rows("PRAGMA user_version", []) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        if version > Self.schemaVersion {
            throw HistoryError.newerVersion
        }
        if version < 1 {
            try transaction {
                try execute(
                    """
                    CREATE TABLE places (
                        id INTEGER PRIMARY KEY,
                        url TEXT NOT NULL UNIQUE,
                        title TEXT NOT NULL DEFAULT '',
                        visit_count INTEGER NOT NULL DEFAULT 0,
                        typed_count INTEGER NOT NULL DEFAULT 0,
                        last_visit REAL NOT NULL,
                        search_text TEXT NOT NULL DEFAULT ''
                    );
                    CREATE INDEX places_last_visit ON places (last_visit);
                    CREATE TABLE visits (
                        id INTEGER PRIMARY KEY,
                        place_id INTEGER NOT NULL REFERENCES places (id) ON DELETE CASCADE,
                        time REAL NOT NULL,
                        transition TEXT NOT NULL
                    );
                    CREATE INDEX visits_place ON visits (place_id);
                    CREATE INDEX visits_time ON visits (time);
                    PRAGMA user_version = \(Self.schemaVersion);
                    """)
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private static func error(_ code: Int32, _ db: OpaquePointer?) -> HistoryError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
        return .database(code: code, message: message)
    }

    private static func check(_ code: Int32, _ db: OpaquePointer?) throws {
        guard code == SQLITE_OK || code == SQLITE_ROW || code == SQLITE_DONE else {
            throw error(code, db)
        }
    }

    private func execute(_ sql: String) throws {
        try Self.check(sqlite3_exec(db, sql, nil, nil, nil), db)
    }

    private func run(_ sql: String, _ args: [Binding]) throws {
        _ = try rows(sql, args) { _ in () as Void? }
    }

    private static func bind(_ args: [Binding], to stmt: OpaquePointer?, _ db: OpaquePointer?) throws {
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            let bound: Int32
            switch arg {
            case .text(let value):
                bound = sqlite3_bind_text(stmt, position, value, Int32(value.utf8.count), sqliteTransient)
            case .int(let value): bound = sqlite3_bind_int64(stmt, position, Int64(value))
            case .double(let value): bound = sqlite3_bind_double(stmt, position, value)
            }
            try check(bound, db)
        }
    }

    /// A statement prepared once and run many times, each run with its own arguments. Finalized when released.
    private final class Statement {
        private let db: OpaquePointer?
        private var stmt: OpaquePointer?

        init(_ db: OpaquePointer?, _ sql: String) throws {
            self.db = db
            try HistoryStore.check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), db)
        }

        deinit { sqlite3_finalize(stmt) }

        /// Runs the statement with `args` and returns whether it produced a row.
        func step(_ args: [Binding]) throws -> Bool {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try HistoryStore.bind(args, to: stmt, db)
            let code = sqlite3_step(stmt)
            try HistoryStore.check(code, db)
            let produced = code == SQLITE_ROW
            sqlite3_reset(stmt)
            return produced
        }
    }

    private func rows<T>(_ sql: String, _ args: [Binding], _ read: (OpaquePointer) -> T?) throws -> [T] {
        var stmt: OpaquePointer?
        try Self.check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), db)
        defer { sqlite3_finalize(stmt) }
        try Self.bind(args, to: stmt, db)
        var result: [T] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_ROW {
                if let stmt, let value = read(stmt) { result.append(value) }
            } else {
                try Self.check(code, db)
                return result
            }
        }
    }
}
