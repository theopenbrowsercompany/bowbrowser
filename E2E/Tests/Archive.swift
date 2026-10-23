import Foundation

/// Tests of auto-archive in the app: a Today tab unused for longer than the profile's threshold (12 hours by default)
/// moves into the archive on a pass and comes back with Reopen, and a damaged archive file keeps its readable entries.
/// The archive clock is moved forward instead of waited on. Uses the store fixture.
@MainActor
enum ArchiveAreaTests {
    static let all: [any E2ETest] = [
        ArchiveExpiryTest(), ArchiveDamagedFileTest(), ArchiveBackgroundSpaceTest(),
        ArchivePopoverTest(), ArchiveThresholdMenuTest(),
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

/// A tab keeping the camera on in a Space that is not on screen stays through a pass at 13 hours, while an idle tab
/// in that same Space archives.
struct ArchiveBackgroundSpaceTest: E2ETest {
    let name = "archive.background-space"

    func run(_ run: E2ERun) async throws {
        let app = try ArchiveAreaTests.app(run)
        guard let edges = run.app as? any E2EWindowEdgesApp else { throw E2EError("the app has no Space switching") }
        defer { app.resetArchive() }
        let window = try await run.step(
            "open a window on Space Other with idle tab Idle", timeout: E2ETimeouts.firstLoad
        ) {
            let seed = E2ESeed(
                spaces: [
                    E2ESeedSpace("Home", pinned: [.tab("A", url: StoreTests.url("A"))]),
                    E2ESeedSpace("Other", today: [.tab("Idle", url: StoreTests.url("Idle"))]),
                ], activeSpace: "Other")
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        guard let idle = window.itemIDs["Idle"], let home = window.spaceIDs["Home"] else {
            throw E2EError("the seed has no Idle tab or Home Space")
        }
        let page = window.page
        let live = try await run.step("start the camera in a tab of Other", timeout: E2ETimeouts.firstLoad) {
            let live = try run.app.openTab(at: E2EFixture.url("unload/capture.html"), besides: page, select: true)
            _ = try await live.waitForLoad(after: 0)
            _ = try await live.evaluate("startCamera()")
            try await live.waitForPermissionPrompt().answer(true)
            let result = try await live.string("window.cameraResult")
            guard result == "live" else { throw E2EError("the camera ended as \(result)") }
            return live
        }
        let liveItem = try app.archiveItem(of: live)
        let archived = try await run.step("switch to Home, pass at clock+13h", timeout: E2ETimeouts.step) {
            try edges.switchToSpace(home, besides: page)
            try app.useManualArchiveClock()
            _ = try app.runArchivePass()
            try app.advanceArchiveClock(by: 13 * 3_600)
            _ = try app.runArchivePass()
            return try app.archivedItems(besides: page)
        }
        run.check(
            name, passed: archived == [idle],
            "clock+13h in Home: archived=\(ArchiveAreaTests.names(archived, in: window)) "
                + "camera tab \(archived.contains(liveItem) ? "archived" : "kept")")
    }
}

/// The footer's archive button opens a popover: empty at first with the seven value threshold menu on the default,
/// then listing the archived tab with its Space and how long ago, and a click on that row puts the tab back in Today,
/// shows it and closes the popover.
struct ArchivePopoverTest: E2ETest {
    let name = "archive.popover"

    func run(_ run: E2ERun) async throws {
        let app = try ArchiveAreaTests.app(run)
        guard let popoverApp = run.app as? any E2EArchivePopoverApp else {
            throw E2EError("the app has no archive popover")
        }
        let window = try await ArchiveAreaTests.openWindow(run)
        let page = window.page
        defer {
            popoverApp.closeArchivePopover(in: page)
            app.resetArchive()
        }
        guard let b = window.itemIDs["B"] else { throw E2EError("the seed has no tab B") }
        let (emptyShown, emptyText, titles, selected) = try await run.step(
            "open the popover with nothing archived", timeout: E2ETimeouts.step
        ) {
            try popoverApp.clickArchiveButton(in: page)
            let menu = try popoverApp.archiveThresholdMenu(in: page)
            return (
                try popoverApp.archivePopoverIsShown(in: page), try popoverApp.archivePopoverShowsEmptyState(in: page),
                menu.titles, menu.selected
            )
        }
        let (closedAgain, rows) = try await run.step("archive B and open the popover again", timeout: E2ETimeouts.step)
        {
            try popoverApp.clickArchiveButton(in: page)
            let closedAgain = try !popoverApp.archivePopoverIsShown(in: page)
            try app.useManualArchiveClock()
            _ = try app.runArchivePass()
            try app.advanceArchiveClock(by: 13 * 3_600)
            _ = try app.runArchivePass()
            try app.advanceArchiveClock(by: 2 * 3_600)
            try popoverApp.clickArchiveButton(in: page)
            return (closedAgain, try popoverApp.archivePopoverRows(in: page))
        }
        let (today, shown, archived, stillShown) = try await run.step("click the row", timeout: E2ETimeouts.step) {
            if rows.contains(where: { $0.item == b }) { try popoverApp.clickArchivePopoverRow(b, in: page) }
            return (
                try app.archiveTodayTabs(besides: page), try app.archiveShownItem(besides: page),
                try app.archivedItems(besides: page), try popoverApp.archivePopoverIsShown(in: page)
            )
        }
        let expectedTitles = ["Never", "1 hour", "6 hours", "12 hours", "24 hours", "7 days", "30 days"]
        let listed =
            rows.count == 1 && rows[0].item == b && !rows[0].title.isEmpty && rows[0].detail == "Home · 2 hours ago"
        let passed =
            emptyShown && emptyText && titles == expectedTitles && selected == "12 hours" && closedAgain && listed
            && today == [b] && shown == b && archived.isEmpty && !stillShown
        run.check(
            name, passed: passed,
            "empty=\(emptyText) menu=\(titles.joined(separator: "/")) selected=\(selected) "
                + "secondClickCloses=\(closedAgain) rows=\(rows.map { "\($0.title) | \($0.detail)" }) "
                + "reopen: today=\(ArchiveAreaTests.names(today, in: window)) shown=\(shown == b) "
                + "archived=\(archived.count) popoverClosed=\(!stillShown)")
    }
}

/// Choosing "1 hour" in the popover's menu is saved for the profile, and the next pass uses it: B, which the default
/// 12 hours would keep at 2 hours, is archived.
struct ArchiveThresholdMenuTest: E2ETest {
    let name = "archive.threshold"

    func run(_ run: E2ERun) async throws {
        let app = try ArchiveAreaTests.app(run)
        guard let popoverApp = run.app as? any E2EArchivePopoverApp else {
            throw E2EError("the app has no archive popover")
        }
        let window = try await ArchiveAreaTests.openWindow(run)
        let page = window.page
        defer {
            popoverApp.closeArchivePopover(in: page)
            app.resetArchive()
        }
        guard let b = window.itemIDs["B"] else { throw E2EError("the seed has no tab B") }
        let (before, after, selected) = try await run.step("choose 1 hour", timeout: E2ETimeouts.step) {
            let before = try popoverApp.archiveSavedThreshold(besides: page)
            try popoverApp.clickArchiveButton(in: page)
            try popoverApp.chooseArchiveThreshold("1 hour", in: page)
            return (
                before, try popoverApp.archiveSavedThreshold(besides: page),
                try popoverApp.archiveThresholdMenu(in: page).selected
            )
        }
        let archived = try await run.step("pass at clock+2h", timeout: E2ETimeouts.step) {
            try app.useManualArchiveClock()
            _ = try app.runArchivePass()
            try app.advanceArchiveClock(by: 2 * 3_600)
            _ = try app.runArchivePass()
            return try app.archivedItems(besides: page)
        }
        run.check(
            name, passed: before == "12 hours" && after == "1 hour" && selected == "1 hour" && archived == [b],
            "saved \(before) -> \(after), menu shows \(selected), "
                + "clock+2h archived=\(ArchiveAreaTests.names(archived, in: window))")
    }
}
