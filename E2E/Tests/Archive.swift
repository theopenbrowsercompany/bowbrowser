import Foundation

/// Tests of auto-archive in the app: a Today tab unused for longer than the profile's threshold (12 hours by default)
/// moves into the archive on a pass and comes back with Reopen, and a damaged archive file keeps its readable entries.
/// The archive clock is moved forward instead of waited on. Uses the store fixture.
@MainActor
enum ArchiveAreaTests {
    static let all: [any E2ETest] = [
        ArchiveExpiryTest(), ArchiveDamagedFileTest(),
    ]

    static func app(_ run: E2ERun) throws -> any E2EArchiveApp {
        guard let app = run.app as? any E2EArchiveApp else { throw E2EError("the app has no auto-archive") }
        return app
    }

    /// Opens a window whose Space has pinned tab A, which it shows, and Today tab B, which has never been selected
    /// (as after a relaunch).
    static func openWindow(_ run: E2ERun) async throws -> E2ESeededWindow {
        try await run.step("open a window with pinned A and Today B", timeout: E2ETimeouts.firstLoad) {
            let seed = E2ESeed(spaces: [
                E2ESeedSpace(
                    "Home", pinned: [.tab("A", url: StoreTests.url("A"))], today: [.tab("B", url: StoreTests.url("B"))])
            ])
            let window = try await app(run).openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
    }

    /// `ids` as the seed's names, for detail text.
    static func names(_ ids: [String], in window: E2ESeededWindow) -> String {
        let byID = Dictionary(uniqueKeysWithValues: window.itemIDs.map { ($0.value, $0.key) })
        return "[" + ids.map { byID[$0] ?? $0 }.joined(separator: ",") + "]"
    }
}

/// A Today tab first seen by a pass is timed from then: 11 hours later it stays, 13 hours later it archives while
/// the pinned tab the window shows stays, and Reopen puts it back in Today and shows it.
struct ArchiveExpiryTest: E2ETest {
    let name = "archive"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let app = try ArchiveAreaTests.app(run)
        defer { app.resetArchive() }
        let window = try await ArchiveAreaTests.openWindow(run)
        let page = window.page
        guard let b = window.itemIDs["B"] else { throw E2EError("the seed has no tab B") }
        let early = try await run.step("first pass, then 11 hours later", timeout: E2ETimeouts.step) {
            guard app.archiverIsRunning else { throw E2EError("the archive timer is not running") }
            try app.useManualArchiveClock()
            // The first pass sees B for the first time and starts timing it.
            var archived = try app.runArchivePass()
            try app.advanceArchiveClock(by: 11 * 3_600)
            archived += try app.runArchivePass()
            return archived
        }
        let (today, archived) = try await run.step("13 hours later", timeout: E2ETimeouts.step) {
            try app.advanceArchiveClock(by: 2 * 3_600)
            _ = try app.runArchivePass()
            return (try app.archiveTodayTabs(besides: page), try app.archivedItems(besides: page))
        }
        let (reopened, todayAfter, shown, archivedAfter) = try await run.step("reopen B", timeout: E2ETimeouts.step) {
            let reopened = try app.reopenArchived(b, besides: page)
            return (
                reopened, try app.archiveTodayTabs(besides: page), try app.archiveShownItem(besides: page),
                try app.archivedItems(besides: page)
            )
        }
        let reopen = reopened && todayAfter == [b] && shown == b && archivedAfter.isEmpty ? "B" : "none"
        var detail =
            "clock+13h today=\(ArchiveAreaTests.names(today, in: window)) "
            + "archived=\(ArchiveAreaTests.names(archived, in: window)) reopen=\(reopen)"
        let passed = early.isEmpty && today.isEmpty && archived == [b] && reopen == "B"
        if !passed {
            detail +=
                " (archived before 13h=\(ArchiveAreaTests.names(early, in: window)) after reopen: "
                + "today=\(ArchiveAreaTests.names(todayAfter, in: window)) "
                + "shown=\(ArchiveAreaTests.names(shown.map { [$0] } ?? [], in: window)) "
                + "archived=\(ArchiveAreaTests.names(archivedAfter, in: window)))"
        }
        run.check(name, passed: passed, detail)
    }
}

/// An archive file with a damaged entry opens with the entry left out and counted, keeps a copy of the file as it
/// was, and archives as usual.
struct ArchiveDamagedFileTest: E2ETest {
    let name = "archive.damaged"

    func run(_ run: E2ERun) async throws {
        let app = try ArchiveAreaTests.app(run)
        defer { app.resetArchive() }
        let window = try await ArchiveAreaTests.openWindow(run)
        let page = window.page
        guard let b = window.itemIDs["B"] else { throw E2EError("the seed has no tab B") }
        let file = try app.archiveFile(besides: page)
        let (skipped, archived, copies) = try await run.step("open a damaged archive", timeout: E2ETimeouts.step) {
            try Data(#"{"version":1,"items":[{"damaged":true}]}"#.utf8).write(to: file)
            // Also makes the next pass read the file afresh.
            try app.useManualArchiveClock()
            _ = try app.runArchivePass()
            try app.advanceArchiveClock(by: 13 * 3_600)
            _ = try app.runArchivePass()
            let folder = file.deletingLastPathComponent()
            let stem = file.deletingPathExtension().lastPathComponent
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            let copies = names.filter { $0.hasPrefix(stem + ".") && $0 != file.lastPathComponent }
            return (try app.archiveSkippedRecords(besides: page), try app.archivedItems(besides: page), copies.count)
        }
        let passed = skipped == 1 && archived == [b] && copies == 1
        run.check(
            name, passed: passed,
            "skipped=\(skipped.map(String.init) ?? "unopened") archived=\(ArchiveAreaTests.names(archived, in: window)) "
                + "copies=\(copies)")
    }
}
