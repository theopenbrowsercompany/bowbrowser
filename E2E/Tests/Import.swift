import BowCore
import Foundation

/// Tests of the Arc importer inside the app process. Fixtures in E2E/Fixtures/import/ (hand built, never real Arc data).
@MainActor
enum ImportTests {
    static let all: [any E2ETest] = [
        ImportParseTest(), ImportApplyTest(), ImportTwiceTest(), ImportRefusalTest(),
    ]

    static func app(of run: E2ERun) throws -> any E2EImportApp {
        guard let app = run.app as? any E2EImportApp else { throw E2EError("the app cannot drive the import wizard") }
        return app
    }

    /// Opens a window on a fixture page and answers the file picker with the fixture `file`.
    static func open(_ run: E2ERun, file: String) async throws -> (app: any E2EImportApp, page: any E2EPage) {
        let app = try app(of: run)
        let page = try await run.app.openWindow(at: E2EFixture.url("import/sidebar.json"))
        try app.useImportFile(file)
        return (app, page)
    }

    /// The wizard once it is on `step` (or gone, for nil), or as it reads last.
    static func wizard(_ app: any E2EImportApp, _ page: any E2EPage, step: String?) async throws
        -> E2EImportWizardState?
    {
        try await E2EWaits.value({ try app.importWizard(in: page) }, until: { $0?.step == step })
    }

    /// Chooses File > Import from Arc… and returns the wizard on its consent step.
    static func start(_ app: any E2EImportApp, _ page: any E2EPage) async throws -> E2EImportWizardState? {
        try app.chooseImportMenuItem(in: page)
        return try await wizard(app, page, step: "consent")
    }

    /// The fixture's tree as the preview and the sidebar show it: both Spaces with their pinned items, then Favorites.
    static let twoSpacesRows = [
        "0:Clients", "1:client", "2:project", "3:phase", "4:A", "4:Kanban", "1:Loose", "1:archive",
        "0:Side", "1:Side",
        "0:Favorites", "1:Mail", "1:Calendar", "1:Chat", "1:Docs",
    ]
}

/// The wizard end to end on a fixture Arc file of two Spaces (nested folders, pinned tabs, four Favorites): File >
/// Import from Arc… opens the consent step, which says what is read and that nothing leaves the Mac; the picker is
/// answered with the fixture only when Choose File… is pressed; unticking a Space leaves it out of the preview;
/// Import adds both Spaces and the Favorites with their nesting as the preview showed it; Undo gives back exactly the
/// sidebar that was there.
struct ImportApplyTest: E2ETest {
    let name = "import.apply"
    let checks = [
        "import.consent", "import.file", "import.spaces", "import.preview", "import.apply", "import.undo",
    ]

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let opened = try await ImportTests.open(run, file: "arc-two-spaces.json")
            _ = try await opened.page.waitForLoad(after: 0)
            return opened
        }
        let mark = try app.markSidebar(in: page)
        let startSpaces = try app.spaceTitles(in: page)

        let consent = try await run.step("File, Import from Arc", timeout: E2ETimeouts.step) {
            let wizard = try await ImportTests.start(app, page)
            return (wizard, try app.importFileRequests(), try app.importMenuItemEnabled(in: page))
        }
        let consentText = consent.0?.text ?? "no wizard"
        run.check(
            "import.consent",
            passed: ["Nothing leaves this Mac", "Spaces", "folders", "pinned tabs", "Favorites", "never changes"]
                .allSatisfy(consentText.contains) && consent.0?.buttons == ["Cancel", "Choose File…"]
                && consent.1 == 0 && !consent.2,
            "buttons=\(consent.0?.buttons ?? []) requests=\(consent.1) menu_enabled=\(consent.2) text=\(consentText)")

        let chosen = try await run.step("Choose File", timeout: E2ETimeouts.step) {
            try app.pressImportButton("Choose File…", in: page)
            let wizard = try await ImportTests.wizard(app, page, step: "spaces")
            return (wizard, try app.importFileRequests())
        }
        run.check(
            "import.file",
            passed: chosen.0?.step == "spaces" && chosen.1 == 1
                && chosen.0?.checkboxes == [
                    "Clients=on", "Side=on", "Include Favorites=on", "Include unpinned tabs=off",
                ] && chosen.0?.mode == "Import Arc Spaces as Spaces",
            "requests=\(chosen.1) \(chosen.0.map(\.description) ?? "no wizard")")

        let spaces = try await run.step("choose Spaces and read the preview", timeout: E2ETimeouts.step) {
            try app.setImportCheckbox("Side", on: false, in: page)
            try app.pressImportButton("Continue", in: page)
            let without = try await ImportTests.wizard(app, page, step: "preview")
            try app.pressImportButton("Back", in: page)
            _ = try await ImportTests.wizard(app, page, step: "spaces")
            try app.setImportCheckbox("Side", on: true, in: page)
            try app.pressImportButton("Continue", in: page)
            let with = try await ImportTests.wizard(app, page, step: "preview")
            return (without, with)
        }
        let withoutSide = spaces.0?.tree ?? []
        run.check(
            "import.spaces",
            passed: withoutSide == Array(ImportTests.twoSpacesRows.prefix(8))
                + Array(ImportTests.twoSpacesRows.suffix(5))
                && !withoutSide.contains("0:Side"),
            "without Side: \(withoutSide)")
        run.check(
            "import.preview", passed: spaces.1?.tree == ImportTests.twoSpacesRows,
            "tree=\(spaces.1?.tree ?? []) text=\(spaces.1?.text ?? "no wizard")")

        let imported = try await run.step("Import", timeout: E2ETimeouts.step) {
            try app.pressImportButton("Import", in: page)
            let wizard = try await ImportTests.wizard(app, page, step: "done")
            let rows = try app.sidebarRows(skippingSpaces: startSpaces.count, in: page)
            return (wizard, rows, try app.spaceTitles(in: page), try app.favoritesCount(in: page))
        }
        run.check(
            "import.apply",
            passed: imported.1 == ImportTests.twoSpacesRows && imported.2 == startSpaces + ["Clients", "Side"]
                && imported.3 == 4 && imported.0?.text.contains("Imported 2 Spaces") == true
                && imported.0?.buttons == ["Undo", "Done"],
            "sidebar=\(imported.1) spaces=\(imported.2) favorites=\(imported.3) \(imported.0.map(\.description) ?? "")")

        let undone = try await run.step("Undo and Done", timeout: E2ETimeouts.step) {
            try app.pressImportButton("Undo", in: page)
            let wizard = try await E2EWaits.value(
                { try app.importWizard(in: page) }, until: { $0?.text.contains("undone") == true })
            let same = try app.sidebarMatches(mark, in: page)
            try app.pressImportButton("Done", in: page)
            let closed = try await ImportTests.wizard(app, page, step: nil) == nil
            return (wizard, same, closed, try app.importMenuItemEnabled(in: page))
        }
        run.check(
            "import.undo",
            passed: undone.0?.buttons == ["Done"] && undone.1 && undone.2 && undone.3,
            "sidebar_same=\(undone.1) closed=\(undone.2) menu_enabled=\(undone.3) \(undone.0.map(\.description) ?? "")")
    }
}

/// Importing the same file twice: the second preview says the Favorites are already there and the sidebar keeps four
/// Favorites (the Spaces come again); Undo of the second import leaves the first as it was.
struct ImportTwiceTest: E2ETest {
    let name = "import.twice"
    let checks = ["import.twice_favorites", "import.twice_undo"]

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let opened = try await ImportTests.open(run, file: "arc-two-spaces.json")
            _ = try await opened.page.waitForLoad(after: 0)
            return opened
        }
        func importOnce(second: Bool) async throws -> (preview: E2EImportWizardState?, done: E2EImportWizardState?) {
            _ = try await ImportTests.start(app, page)
            try app.pressImportButton("Choose File…", in: page)
            _ = try await ImportTests.wizard(app, page, step: "spaces")
            try app.pressImportButton("Continue", in: page)
            let preview = try await ImportTests.wizard(app, page, step: "preview")
            try app.pressImportButton("Import", in: page)
            let done = try await ImportTests.wizard(app, page, step: "done")
            return (preview, done)
        }
        let first = try await run.step("first import", timeout: E2ETimeouts.step) {
            let result = try await importOnce(second: false)
            try app.pressImportButton("Done", in: page)
            _ = try await ImportTests.wizard(app, page, step: nil)
            return result
        }
        let afterFirst = try app.markSidebar(in: page)
        let second = try await run.step("second import", timeout: E2ETimeouts.step) {
            let result = try await importOnce(second: true)
            let favorites = try app.favoritesCount(in: page)
            let spaces = try app.spaceTitles(in: page)
            return (result, favorites, spaces)
        }
        run.check(
            "import.twice_favorites",
            passed: first.preview?.tree.contains("0:Favorites") == true
                && second.0.preview?.tree.contains("0:Favorites") == false
                && second.0.preview?.text.contains("Already in your Favorites") == true && second.1 == 4
                && second.2.suffix(4) == ["Clients", "Side", "Clients", "Side"],
            "favorites=\(second.1) spaces=\(second.2) preview=\(second.0.preview?.text ?? "none")")
        let undone = try await run.step("Undo the second import", timeout: E2ETimeouts.step) {
            try app.pressImportButton("Undo", in: page)
            _ = try await E2EWaits.value(
                { try app.importWizard(in: page) }, until: { $0?.text.contains("undone") == true })
            let same = try app.sidebarMatches(afterFirst, in: page)
            try app.pressImportButton("Done", in: page)
            _ = try await ImportTests.wizard(app, page, step: nil)
            return same
        }
        run.check("import.twice_undo", passed: undone, "sidebar_same=\(undone)")
    }
}

/// A file that is not an Arc sidebar file stops at a clear message and changes nothing, and Cancel at the consent
/// step closes the wizard without asking for a file.
struct ImportRefusalTest: E2ETest {
    let name = "import.refusal"
    let checks = ["import.refusal_cancel", "import.refusal_badfile"]

    func run(_ run: E2ERun) async throws {
        let (app, page) = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let opened = try await ImportTests.open(run, file: "not-arc.json")
            _ = try await opened.page.waitForLoad(after: 0)
            return opened
        }
        let mark = try app.markSidebar(in: page)
        let cancelled = try await run.step("Cancel at consent", timeout: E2ETimeouts.step) {
            _ = try await ImportTests.start(app, page)
            try app.pressImportButton("Cancel", in: page)
            let closed = try await ImportTests.wizard(app, page, step: nil) == nil
            return (closed, try app.importFileRequests())
        }
        run.check(
            "import.refusal_cancel", passed: cancelled.0 && cancelled.1 == 0,
            "closed=\(cancelled.0) requests=\(cancelled.1)")
        let refused = try await run.step("not an Arc file", timeout: E2ETimeouts.step) {
            _ = try await ImportTests.start(app, page)
            try app.pressImportButton("Choose File…", in: page)
            let failed = try await ImportTests.wizard(app, page, step: "failed")
            let same = try app.sidebarMatches(mark, in: page)
            try app.pressImportButton("Cancel", in: page)
            let closed = try await ImportTests.wizard(app, page, step: nil) == nil
            return (failed, same, closed)
        }
        run.check(
            "import.refusal_badfile",
            passed: refused.0?.text.contains("not an Arc sidebar file") == true
                && refused.0?.buttons == ["Cancel", "Choose Another File…"] && refused.1 && refused.2,
            "sidebar_same=\(refused.1) closed=\(refused.2) \(refused.0.map(\.description) ?? "no wizard")")
    }
}

/// Serves a hand built sidebar file, runs the importer's dry run on its bytes and checks the report's counts.
struct ImportParseTest: E2ETest {
    let name = "import.parse"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("import/sidebar.json"))
        }
        let data = try await run.step("load fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
            let text = try await page.string("document.body.innerText")
            guard let data = text.data(using: .utf8), !data.isEmpty else { throw E2EError("the fixture is empty") }
            return data
        }
        try await run.step("dry run", timeout: E2ETimeouts.step) {
            let result = try ArcImporter.parse(data)
            let report = result.report
            // The folder depth is also computed from the parsed model, apart from the report's own count.
            let depth =
                result.spaces.map { space in
                    max(Self.depth(of: space.pinned), Self.depth(of: space.unpinned))
                }.max() ?? 0
            let counts = "spaces=\(report.spaces) folders=\(report.folders) depth=\(depth) pinned=\(report.pinnedTabs)"
            let agrees = depth == report.maxFolderDepth && report.skipped.isEmpty
            run.check(
                name, passed: counts == "spaces=3 folders=5 depth=3 pinned=18" && agrees,
                agrees ? counts : "\(counts) (report depth \(report.maxFolderDepth), skipped \(report.skipped.count))")
        }
    }

    private static func depth(of nodes: [ArcImportNode]) -> Int {
        nodes.map { node in
            if case .folder(let folder) = node { return 1 + depth(of: folder.children) }
            return 0
        }.max() ?? 0
    }
}
