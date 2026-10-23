import Foundation

/// Tests of the Arc import's history and bookmarks step. The User Data folders are built from E2E/Fixtures/import/
/// (hand written Local State, Bookmarks and History.sql files, with decoy Cookies and Login Data), never real Arc
/// data.
@MainActor
enum ImportHistoryTests {
    static let all: [any E2ETest] = [ImportHistoryTest(), ImportHistorySkipTest()]

    typealias App = any E2EImportHistoryApp & E2ECommandBarApp & E2EMenuApp

    static func app(of run: E2ERun) throws -> App {
        guard let app = run.app as? App else { throw E2EError("the app cannot drive the history import") }
        return app
    }

    /// Opens a window and answers the folder picker with a User Data folder built from the fixture `fixture`.
    static func open(_ run: E2ERun, fixture: String) async throws -> (app: App, page: any E2EPage, folder: URL) {
        let app = try app(of: run)
        let page = try await run.app.openWindow(at: E2EFixture.url("import/sidebar.json"))
        _ = try await page.waitForLoad(after: 0)
        guard let folder = try app.useImportFolder(fixture) else { throw E2EError("no folder was built") }
        return (app, page, folder)
    }

    /// File > Import from Arc…, then History and Bookmarks…: the wizard once it shows the history step.
    static func startHistory(_ app: App, _ page: any E2EPage) async throws -> E2EImportWizardState? {
        _ = try await ImportTests.start(app, page)
        try app.pressImportButton("History and Bookmarks…", in: page)
        return try await ImportTests.wizard(app, page, step: "history")
    }

    static func visits(_ entries: [E2EHistoryEntry], _ path: String) -> Int {
        entries.first { $0.url.absoluteString.hasSuffix("/\(path)") }?.visitCount ?? 0
    }

    /// The bookmarks fixture as the pinned section shows it under the folder.
    static let bookmarkRows = [
        "0:Arc Bookmarks", "1:Bookmarks bar", "2:Docs", "2:Reading", "3:Deep", "4:Nested", "3:Article",
        "1:Other bookmarks", "2:Other",
    ]
}

/// The history step end to end on a User Data folder with two profiles: Personal (Default) maps to Bow's default
/// profile; Work (Profile 7) has no Bow profile, so its visits go to the profile of the Space on screen and the
/// preview says so. Import puts the visits in those histories (the command bar finds them) and the Default
/// profile's bookmarks in one pinned folder with their nesting; only Local State, Bookmarks and copies of History
/// were opened and the copies are gone; Undo takes out the visits and the folder.
struct ImportHistoryTest: E2ETest {
    let name = "import.history"
    let checks = ["import.history", "import.history_bookmarks", "import.history_files", "import.history_undo"]

    func run(_ run: E2ERun) async throws {
        let (app, page, folder) = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            try await ImportHistoryTests.open(run, fixture: "userdata")
        }
        defer { _ = try? app.useImportFolder(nil) }
        let mark = try app.markSidebar(in: page)
        let pinnedBefore = try app.pinnedRows(in: page)
        let ownBefore = try app.historyEntries(of: page)
        let defaultBefore = try app.defaultProfileHistory()

        let preview = try await run.step("File, Import from Arc, History and Bookmarks", timeout: E2ETimeouts.step) {
            try await ImportHistoryTests.startHistory(app, page)
        }
        let imported = try await run.step("Import", timeout: E2ETimeouts.step) {
            try app.pressImportButton("Import", in: page)
            let done = try await ImportTests.wizard(app, page, step: "done")
            return (done, try app.historyEntries(of: page), try app.defaultProfileHistory())
        }
        let found = try await run.step("Cmd+T, type zephyr", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "t", modifiers: .command, in: page)
            let bar = try app.commandBar(of: page)
            try bar.type("zephyr")
            let rows = try await bar.waitForResults()
            try bar.press(.escape)
            return rows.first { $0.kind == "history" }
        }
        let own = imported.1
        let added = ImportHistoryTests.visits(own, "zephyr-arc") + ImportHistoryTests.visits(own, "quokka-arc")
        let previewText = preview?.text ?? "no wizard"
        run.check(
            "import.history",
            passed: added > 0 && ImportHistoryTests.visits(own, "zephyr-arc") == 2
                && ImportHistoryTests.visits(own, "quokka-arc") == 1
                && ImportHistoryTests.visits(imported.2, "default-arc") == 2
                && !own.contains { $0.url.absoluteString.contains("settings") || $0.url.host == "ads.example.com" }
                && found?.url.absoluteString == "https://example.com/zephyr-arc"
                && previewText.contains("Personal: 2 visits and 4 bookmarks, into the Default profile")
                && previewText.contains("Work: 3 visits. No Bow profile matches this Arc profile")
                && imported.0?.text.contains("Imported 5 visits") == true,
            (added > 0 ? "visits>0" : "visits=0") + " work="
                + "\(own.map { "\($0.url.lastPathComponent)x\($0.visitCount)" }) "
                + "default=\(ImportHistoryTests.visits(imported.2, "default-arc")) "
                + "cmdbar=\(found?.description ?? "no history row") preview=\(previewText) "
                + "done=\(imported.0?.text ?? "none")")

        let pinned = try app.pinnedRows(in: page)
        run.check(
            "import.history_bookmarks",
            passed: pinned == pinnedBefore + ImportHistoryTests.bookmarkRows
                && imported.0?.text.contains("4 bookmarks into Arc Bookmarks") == true,
            "pinned=\(pinned) done=\(imported.0?.text ?? "none")")

        let log = try app.importFileLog(relativeTo: folder)
        run.check(
            "import.history_files",
            passed: log?.originals == ["Local State", "Default/History", "Default/Bookmarks", "Profile 7/History"]
                && log?.openedOnlyCopies == true && (log?.openedCount ?? 0) >= 2 && log?.copiesRemoved == true,
            log?.description ?? "no file log")

        let undone = try await run.step("Undo and Done", timeout: E2ETimeouts.step) {
            try app.pressImportButton("Undo", in: page)
            let wizard = try await E2EWaits.value(
                { try app.importWizard(in: page) }, until: { $0?.text.contains("undone") == true })
            let state = (
                wizard, try app.sidebarMatches(mark, in: page), try app.historyEntries(of: page),
                try app.defaultProfileHistory()
            )
            try app.pressImportButton("Done", in: page)
            _ = try await ImportTests.wizard(app, page, step: nil)
            return state
        }
        run.check(
            "import.history_undo",
            passed: undone.0?.buttons == ["Done"] && undone.1 && undone.2 == ownBefore && undone.3 == defaultBefore,
            "sidebar_same=\(undone.1) own_same=\(undone.2 == ownBefore) default_same=\(undone.3 == defaultBefore) "
                + (undone.0.map(\.description) ?? "no wizard"))
    }
}

/// Skip bookmarks: the visits come and the sidebar stays as it was. Importing the same folder again adds no visit,
/// so nothing repeats in history. The folder has one profile with no Bow profile, so everything goes to the test's
/// own profile and nothing outlives the test.
struct ImportHistorySkipTest: E2ETest {
    let name = "import.history_skip"
    let checks = ["import.history_skip", "import.history_twice"]

    func run(_ run: E2ERun) async throws {
        let (app, page, _) = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            try await ImportHistoryTests.open(run, fixture: "userdata-work")
        }
        defer { _ = try? app.useImportFolder(nil) }
        let mark = try app.markSidebar(in: page)
        let first = try await run.step("import with Skip bookmarks", timeout: E2ETimeouts.step) {
            let preview = try await ImportHistoryTests.startHistory(app, page)
            try app.chooseImportMode("Skip bookmarks", in: page)
            let skipped = try await E2EWaits.value(
                { try app.importWizard(in: page) }, until: { $0?.mode == "Skip bookmarks" })
            try app.pressImportButton("Import", in: page)
            let done = try await ImportTests.wizard(app, page, step: "done")
            let state = (
                preview, skipped, done, try app.sidebarMatches(mark, in: page), try app.historyEntries(of: page)
            )
            try app.pressImportButton("Done", in: page)
            _ = try await ImportTests.wizard(app, page, step: nil)
            return state
        }
        run.check(
            "import.history_skip",
            passed: first.0?.mode == "Bookmarks as a pinned folder"
                && first.0?.text.contains("3 visits and 4 bookmarks") == true
                && first.1?.text.contains("Work: 3 visits.") == true && first.3
                && ImportHistoryTests.visits(first.4, "zephyr-arc") == 2
                && first.2?.text.contains("bookmark") == false,
            "sidebar_same=\(first.3) preview=\(first.0?.text ?? "none") skipped=\(first.1?.text ?? "none") "
                + "done=\(first.2?.text ?? "none")")

        let second = try await run.step("import the same folder again", timeout: E2ETimeouts.step) {
            _ = try await ImportHistoryTests.startHistory(app, page)
            try app.chooseImportMode("Skip bookmarks", in: page)
            _ = try await E2EWaits.value({ try app.importWizard(in: page) }, until: { $0?.mode == "Skip bookmarks" })
            try app.pressImportButton("Import", in: page)
            let done = try await ImportTests.wizard(app, page, step: "done")
            let state = (done, try app.historyEntries(of: page), try app.sidebarMatches(mark, in: page))
            try app.pressImportButton("Done", in: page)
            _ = try await ImportTests.wizard(app, page, step: nil)
            return state
        }
        run.check(
            "import.history_twice",
            passed: second.1 == first.4 && second.2 && second.0?.text.contains("Imported 0 visits") == true
                && second.0?.text.contains("3 visits were already in your history") == true
                && second.0?.buttons == ["Done"],
            "same_history=\(second.1 == first.4) sidebar_same=\(second.2) \(second.0.map(\.description) ?? "none")")
    }
}
