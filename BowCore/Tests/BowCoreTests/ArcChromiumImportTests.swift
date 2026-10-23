import Foundation
import SQLite3
import Testing

@testable import BowCore

/// All data here is written by hand with example.com URLs: no real browser profile is ever read.
@Suite struct ArcChromiumImportTests {
    // 1_700_000_000 seconds after 1970 expressed as WebKit microseconds.
    static let t0: Int64 = 13_344_473_600_000_000
    static let t0Date = Date(timeIntervalSince1970: 1_700_000_000)

    static let localState = """
        {"profile":{"info_cache":{
          "Profile 10":{"name":"Side"},
          "Default":{"name":"Personal"},
          "Profile 2":{"name":""},
          "Profile 1":{"name":"Work"},
          "Broken":"not an object"
        },"last_used":"Default"},"other":1}
        """

    static let bookmarks = """
        {"checksum":"x","roots":{
          "other":{"name":"Other bookmarks","type":"folder","children":[
            {"type":"url","name":"Other","url":"https://example.com/other","date_added":"13344473600000000"}]},
          "bookmark_bar":{"name":"Bookmarks bar","type":"folder","children":[
            {"type":"url","name":"Home","url":"https://example.com/","date_added":"13344473600000000"},
            {"type":"folder","name":"Reading","date_added":"13344473601000000","children":[
              {"type":"folder","name":"Deep","children":[
                {"type":"url","name":"Nested","url":"https://example.com/nested","date_added":"0"}]},
              {"type":"url","name":"Article","url":"https://example.com/a"}]},
            {"type":"url","name":"No URL"},
            {"type":"mystery","name":"Unknown"}]},
          "custom_root":{"name":"Custom","type":"folder","children":[]},
          "sync_transaction_version":"3"
        },"version":1}
        """

    // MARK: Local State

    @Test func profilesAreOrderedAndNamed() throws {
        let profiles = try ChromiumProfileList.parse(data: Data(Self.localState.utf8))
        #expect(
            profiles == [
                ChromiumProfile(directory: "Default", displayName: "Personal"),
                ChromiumProfile(directory: "Profile 1", displayName: "Work"),
                ChromiumProfile(directory: "Profile 2", displayName: "Profile 2"),
                ChromiumProfile(directory: "Profile 10", displayName: "Side"),
            ])
    }

    @Test(arguments: ["", "not json", "[]", "{}", "{\"profile\":{}}", "{\"profile\":{\"info_cache\":[]}}"])
    func malformedLocalStateThrows(_ text: String) {
        #expect(throws: ChromiumImportError.self) { try ChromiumProfileList.parse(data: Data(text.utf8)) }
    }

    @Test func emptyInfoCacheGivesNoProfiles() throws {
        #expect(try ChromiumProfileList.parse(data: Data("{\"profile\":{\"info_cache\":{}}}".utf8)).isEmpty)
    }

    @Test func missingLocalStateIsReported() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ChromiumImportError.missingFile("Local State")) {
            try ChromiumProfileList.load(userDataFolder: folder)
        }
    }

    // MARK: Bookmarks

    @Test func bookmarksKeepRootsFoldersAndDates() throws {
        let parsed = try ChromiumBookmarks.parse(data: Data(Self.bookmarks.utf8))
        #expect(parsed.roots.map(\.key) == ["bookmark_bar", "other", "custom_root"])
        #expect(parsed.roots[0].title == "Bookmarks bar")
        #expect(parsed.roots[0].children.count == 2)
        #expect(parsed.roots[0].children[0] == .url(title: "Home", url: "https://example.com/", dateAdded: Self.t0Date))
        guard case .folder(let title, let added, let children) = parsed.roots[0].children[1] else {
            Issue.record("expected a folder")
            return
        }
        #expect(title == "Reading")
        #expect(added == Self.t0Date.addingTimeInterval(1))
        guard case .folder("Deep", nil, let deep) = children[0] else {
            Issue.record("expected nested folder")
            return
        }
        // "0" means never, and a missing date is nil too.
        #expect(deep == [.url(title: "Nested", url: "https://example.com/nested", dateAdded: nil)])
        #expect(children[1] == .url(title: "Article", url: "https://example.com/a", dateAdded: nil))
    }

    @Test func bookmarkCounts() throws {
        let parsed = try ChromiumBookmarks.parse(data: Data(Self.bookmarks.utf8))
        #expect(parsed.bookmarkCount == 4)
        #expect(parsed.folderCount == 2)
    }

    @Test(arguments: ["", "nope", "[]", "{}", "{\"roots\":[]}"])
    func malformedBookmarksThrow(_ text: String) {
        #expect(throws: ChromiumImportError.self) { try ChromiumBookmarks.parse(data: Data(text.utf8)) }
    }

    @Test func emptyRootsGiveNoBookmarks() throws {
        let parsed = try ChromiumBookmarks.parse(data: Data("{\"roots\":{}}".utf8))
        #expect(parsed.roots.isEmpty)
        #expect(parsed.bookmarkCount == 0)
    }

    @Test func missingBookmarksFileIsReported() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ChromiumImportError.missingFile("Bookmarks")) {
            try ChromiumBookmarks.load(profileFolder: folder)
        }
    }

    // MARK: History

    @Test func historyReadsVisitsInOrderAndSkipsInternalPages() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.writeHistory(to: folder)
        let visits = try ChromiumHistory.load(profileFolder: folder)
        #expect(visits.map(\.url) == ["https://example.com/a", "https://example.com/a", "https://example.com/b"])
        #expect(visits[0].title == "Page A")
        #expect(visits[0].date == Self.t0Date)
        #expect(visits[1].date == Self.t0Date.addingTimeInterval(60))
        // Transition 0x00000001 is typed; the high bits are qualifiers and are dropped.
        #expect(visits[0].isTyped)
        #expect(visits[1].transition == 0)
        #expect(visits[2].title == "")
    }

    @Test func historyCanKeepNonWebVisits() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.writeHistory(to: folder)
        let visits = try ChromiumHistory.load(profileFolder: folder, webOnly: false)
        #expect(visits.count == 4)
    }

    @Test func historyLeavesTheOriginalUntouchedAndCleansUp() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Self.writeHistory(to: folder)
        let path = folder.appendingPathComponent("History")
        let before = try Data(contentsOf: path)
        _ = try ChromiumHistory.load(profileFolder: folder)
        #expect(try Data(contentsOf: path) == before)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("History-journal").path))
    }

    @Test func historyIncludesCommittedWalFramesFromARunningWriter() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try Self.writeHistory(to: folder, closeAfterwards: false)
        defer { sqlite3_close(db) }
        // A browser in WAL mode that never checkpoints: new visits live only in the -wal file.
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil) == SQLITE_OK)
        let later = Self.t0 + 300_000_000
        #expect(
            sqlite3_exec(
                db,
                """
                INSERT INTO urls (id, url, title) VALUES (4, 'https://example.com/wal', 'From the WAL');
                INSERT INTO visits (url, visit_time, transition) VALUES (4, \(later), 0);
                BEGIN;
                INSERT INTO visits (url, visit_time, transition) VALUES (4, \(later + 1), 0);
                """, nil, nil, nil) == SQLITE_OK)
        let main = folder.appendingPathComponent("History")
        let before = try Data(contentsOf: main)
        let visits = try ChromiumHistory.load(profileFolder: folder)
        // The committed WAL visit is there, the writer's open transaction is not.
        #expect(visits.last?.url == "https://example.com/wal")
        #expect(visits.count == 4)
        #expect(try Data(contentsOf: main) == before)
    }

    @Test func undatedVisitsAreCountedNotSilentlyDropped() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try Self.writeHistory(to: folder, closeAfterwards: false)
        sqlite3_exec(db, "INSERT INTO visits (url, visit_time, transition) VALUES (1, 0, 0);", nil, nil, nil)
        sqlite3_close(db)
        let report = try ChromiumHistory.loadReport(profileFolder: folder)
        #expect(report.visits.count == 3)
        #expect(report.undatedCount == 1)

        let userData = folder.appendingPathComponent("ud")
        let profileFolder = userData.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profileFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: folder.appendingPathComponent("History"), to: profileFolder.appendingPathComponent("History"))
        let summary = ChromiumImportSummary.dryRun(
            userDataFolder: userData, profile: ChromiumProfile(directory: "Default", displayName: "P"))
        #expect(summary.problems.contains(.undatedVisits(count: 1)))
    }

    @Test func missingHistoryIsReported() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ChromiumImportError.missingFile("History")) {
            try ChromiumHistory.load(profileFolder: folder)
        }
    }

    @Test func nonDatabaseHistoryThrows() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("this is not sqlite, it is just text padding padding padding".utf8)
            .write(to: folder.appendingPathComponent("History"))
        #expect(throws: ChromiumImportError.self) { try ChromiumHistory.load(profileFolder: folder) }
    }

    @Test func databaseWithoutTablesThrows() throws {
        let folder = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try Self.openDatabase(folder.appendingPathComponent("History"))
        sqlite3_exec(db, "CREATE TABLE other (id INTEGER)", nil, nil, nil)
        sqlite3_close(db)
        #expect(throws: ChromiumImportError.self) { try ChromiumHistory.load(profileFolder: folder) }
    }

    // MARK: Dry run

    @Test func dryRunSummarizesAProfile() throws {
        let userData = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: userData) }
        let profileFolder = userData.appendingPathComponent("Default")
        try FileManager.default.createDirectory(at: profileFolder, withIntermediateDirectories: true)
        try Self.writeHistory(to: profileFolder)
        try Data(Self.bookmarks.utf8).write(to: profileFolder.appendingPathComponent("Bookmarks"))
        try Data(Self.localState.utf8).write(to: userData.appendingPathComponent("Local State"))

        let profile = try #require(try ChromiumProfileList.load(userDataFolder: userData).first)
        let summary = ChromiumImportSummary.dryRun(userDataFolder: userData, profile: profile)
        #expect(summary.visitCount == 3)
        #expect(summary.distinctURLCount == 2)
        #expect(summary.earliestVisit == Self.t0Date)
        #expect(summary.latestVisit == Self.t0Date.addingTimeInterval(120))
        #expect(summary.bookmarkCount == 4)
        #expect(summary.bookmarkFolderCount == 2)
        #expect(summary.problems.isEmpty)
        #expect(summary.text == "Personal: 3 visits to 2 pages, 4 bookmarks in 2 folders")
    }

    @Test func dryRunReportsMissingFilesAndKeepsTheRest() throws {
        let userData = try Self.tempFolder()
        defer { try? FileManager.default.removeItem(at: userData) }
        let profileFolder = userData.appendingPathComponent("Profile 1")
        try FileManager.default.createDirectory(at: profileFolder, withIntermediateDirectories: true)
        try Data(Self.bookmarks.utf8).write(to: profileFolder.appendingPathComponent("Bookmarks"))

        let summary = ChromiumImportSummary.dryRun(
            userDataFolder: userData, profile: ChromiumProfile(directory: "Profile 1", displayName: "Work"))
        #expect(summary.visitCount == 0)
        #expect(summary.bookmarkCount == 4)
        #expect(summary.problems == [.missingFile("History")])
        #expect(summary.earliestVisit == nil)
    }

    @Test func profileKeysThatEscapeUserDataAreSkipped() throws {
        let text = "{\"profile\":{\"info_cache\":{\"../x\":{\"name\":\"Bad\"},\"..\":{},\"Default\":{}}}}"
        #expect(try ChromiumProfileList.parse(data: Data(text.utf8)).map(\.directory) == ["Default"])
        let summary = ChromiumImportSummary.dryRun(
            userDataFolder: FileManager.default.temporaryDirectory,
            profile: ChromiumProfile(directory: "../x", displayName: "Bad"))
        #expect(summary.problems.count == 1)
    }

    @Test func summaryTextPluralizesAndSkipsMissingBookmarks() {
        let profile = ChromiumProfile(directory: "Default", displayName: "P")
        let visit = ChromiumVisit(url: "https://example.com/", title: "", date: Self.t0Date, transition: 0)
        let summary = ChromiumImportSummary(profile: profile, visits: [visit], bookmarks: nil)
        #expect(summary.text == "P: 1 visit to 1 page")
    }

    // MARK: Helpers

    static func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func openDatabase(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw ChromiumImportError.database(file: "test", reason: "open")
        }
        return db
    }

    /// Writes a History database with the columns Chromium uses (a subset), two web pages, one chrome:// page.
    @discardableResult
    static func writeHistory(to folder: URL, closeAfterwards: Bool = true) throws -> OpaquePointer {
        let db = try openDatabase(folder.appendingPathComponent("History"))
        let t1 = t0 + 60_000_000
        let t2 = t0 + 120_000_000
        let sql = """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
              visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, from_visit INTEGER,
              transition INTEGER, visit_duration INTEGER);
            INSERT INTO urls (id, url, title) VALUES (1, 'https://example.com/a', 'Page A');
            INSERT INTO urls (id, url, title) VALUES (2, 'https://example.com/b', NULL);
            INSERT INTO urls (id, url, title) VALUES (3, 'chrome://settings/', 'Settings');
            INSERT INTO visits (url, visit_time, transition) VALUES (1, \(t0), 805306369);
            INSERT INTO visits (url, visit_time, transition) VALUES (1, \(t1), 0);
            INSERT INTO visits (url, visit_time, transition) VALUES (2, \(t2), 805306368);
            INSERT INTO visits (url, visit_time, transition) VALUES (3, \(t2), 0);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ChromiumImportError.database(file: "test", reason: String(cString: sqlite3_errmsg(db)))
        }
        if closeAfterwards { sqlite3_close(db) }
        return db
    }
}
