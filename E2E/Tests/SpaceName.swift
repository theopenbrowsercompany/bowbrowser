import Foundation

/// The Space name above the Space's tabs, used the way a person uses it: a double click opens the rename sheet with the
/// name selected, Return saves what was typed and Escape keeps the old name, and its context menu, built without
/// showing it, lists the Space's items and the pinned section's. Reuses the sidebar fixtures.
@MainActor
enum SpaceNameTests {
    static let all: [any E2ETest] = [SpaceNameRenameTest(), SpaceNameMenuTest()]

    static func app(of run: E2ERun) throws -> any E2ESpaceNameApp & E2EStoreSeedApp {
        guard let app = run.app as? any E2ESpaceNameApp & E2EStoreSeedApp else {
            throw E2EError("the app cannot drive the Space name")
        }
        return app
    }

    /// Opens the rename sheet with a double click on the Space name and returns its message and field once the field
    /// shows `name`, or as they read last.
    static func startRename(_ app: any E2ESpaceNameApp, _ page: any E2EPage, name: String) async throws
        -> (message: String, field: String, allSelected: Bool)
    {
        try app.doubleClickSpaceName(in: page)
        let field = try await E2EWaits.value({ try app.sheetField(in: page) }, until: { $0?.text == name })
        return (try app.sheetMessage(in: page) ?? "no sheet", field?.text ?? "no field", field?.allSelected ?? false)
    }

    /// The window's Spaces once its sheet has closed and `done` holds, or as they read last.
    static func afterSheet(
        _ app: any E2ESpaceNameApp, _ page: any E2EPage, until done: @escaping (E2ESpacesState) -> Bool
    ) async throws -> (closed: Bool, spaces: E2ESpacesState) {
        let closed = try await E2EWaits.until { try app.sheetMessage(in: page) == nil }
        let spaces = try await E2EWaits.value({ try app.spaces(of: page) }, until: done)
        return (closed, spaces)
    }
}

/// Seeds "work" (A, B) and "personal" (C) with "work" on screen. A double click on the Space name opens the rename
/// sheet with "work" selected; typing "studio" and Return renames it in the store, the header and the switcher. A
/// second double click, "nope" and Escape keeps "studio"; a third that clears the name and presses Return keeps it
/// too. With "personal" shown (Ctrl+2), a double click renames "personal", and "studio" stays as it is.
struct SpaceNameRenameTest: E2ETest {
    let name = "spacename.rename"
    let checks = [
        "spacename.rename_return", "spacename.rename_escape", "spacename.rename_empty", "spacename.rename_other_space",
    ]

    func run(_ run: E2ERun) async throws {
        let app = try SpaceNameTests.app(of: run)
        let page = try await SpacesAreaTests.openWorkAndPersonal(run, app: app)

        let saved = try await run.step("double click, type and Return", timeout: E2ETimeouts.step) {
            let sheet = try await SpaceNameTests.startRename(app, page, name: "work")
            try app.typeInSheet("studio", in: page)
            try app.pressSheetKey(.returnKey, in: page)
            let after = try await SpaceNameTests.afterSheet(app, page) {
                $0.spaces.first == "studio" && $0.header == "studio"
            }
            return (sheet, after)
        }
        run.check(
            "spacename.rename_return",
            passed: saved.0.message.contains("Rename Space") && saved.0.field == "work" && saved.0.allSelected
                && saved.1.closed && saved.1.spaces.spaces == ["studio", "personal"]
                && saved.1.spaces.header == "studio" && saved.1.spaces.footer == ["studio*", "personal"],
            "sheet=\(saved.0.message) field=\(saved.0.field) selected=\(saved.0.allSelected) "
                + "closed=\(saved.1.closed) \(saved.1.spaces)")

        let cancelled = try await run.step("double click, type and Escape", timeout: E2ETimeouts.step) {
            let sheet = try await SpaceNameTests.startRename(app, page, name: "studio")
            try app.typeInSheet("nope", in: page)
            let typed = try app.sheetField(in: page)?.text ?? "no field"
            try app.pressSheetKey(.escape, in: page)
            let after = try await SpaceNameTests.afterSheet(app, page) { _ in true }
            return (sheet.field, typed, after)
        }
        run.check(
            "spacename.rename_escape",
            passed: cancelled.0 == "studio" && cancelled.1 == "nope" && cancelled.2.closed
                && cancelled.2.spaces.spaces == ["studio", "personal"] && cancelled.2.spaces.header == "studio",
            "field=\(cancelled.0) typed=\(cancelled.1) closed=\(cancelled.2.closed) \(cancelled.2.spaces)")

        let empty = try await run.step("double click, clear and Return", timeout: E2ETimeouts.step) {
            _ = try await SpaceNameTests.startRename(app, page, name: "studio")
            try app.typeInSheet("", in: page)
            let typed = try app.sheetField(in: page)?.text ?? "no field"
            try app.pressSheetKey(.returnKey, in: page)
            let after = try await SpaceNameTests.afterSheet(app, page) { _ in true }
            return (typed, after)
        }
        run.check(
            "spacename.rename_empty",
            passed: empty.0.isEmpty && empty.1.closed && empty.1.spaces.spaces == ["studio", "personal"]
                && empty.1.spaces.header == "studio",
            "typed=\(empty.0.debugDescription) closed=\(empty.1.closed) \(empty.1.spaces)")

        let other = try await run.step("rename personal while it is shown", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "2", modifiers: .control, in: page)
            _ = try await E2EWaits.value({ try app.spaces(of: page) }, until: { $0.header == "personal" })
            let sheet = try await SpaceNameTests.startRename(app, page, name: "personal")
            try app.typeInSheet("home", in: page)
            try app.pressSheetKey(.returnKey, in: page)
            let after = try await SpaceNameTests.afterSheet(app, page) { $0.spaces.last == "home" }
            return (sheet.field, after)
        }
        run.check(
            "spacename.rename_other_space",
            passed: other.0 == "personal" && other.1.closed && other.1.spaces.spaces == ["studio", "home"]
                && other.1.spaces.active == "home" && other.1.spaces.header == "home",
            "field=\(other.0) closed=\(other.1.closed) \(other.1.spaces)")
    }
}

/// Seeds "work" (A, B) and "personal" (C) and reads the Space name's context menu, built through the view's own
/// `menu(for:)` so it never pops up: Rename Space… and Delete Space…, then the pinned section's items: New Folder, the
/// Profile submenu (Default, then New Profile… and Delete Profile…), the Theme submenu with each color, Change Icon… and Remove Icon (disabled with no icon). Its Rename Space… opens the
/// same rename sheet, which Escape closes.
struct SpaceNameMenuTest: E2ETest {
    let name = "spacename.menu"
    let tags = ["smoke"]

    static let expected =
        ["Rename Space…", "Delete Space…", "-", "New Folder", "-"]
        + ["Profile", "Profile/Default", "Profile/-", "Profile/New Profile…", "Profile/Delete Profile…", "-"]
        + ["Theme", "Theme/Default*"]
        + ["Blue", "Jam", "Apricot", "Cocoa", "Green", "Brick"].map { "Theme/\($0)" }
        + ["Change Icon…", "Remove Icon!"]
    /// The profiles other tests of the run created also show in the Profile submenu; only the fixed entries count.
    /// Delete Profile… is enabled only while some of those profiles is unused, so its enabled mark is left out.
    static let fixedProfileEntries: Set<String> = [
        "Profile/Default", "Profile/-", "Profile/New Profile…", "Profile/Delete Profile…",
    ]

    func run(_ run: E2ERun) async throws {
        let app = try SpaceNameTests.app(of: run)
        let page = try await SpacesAreaTests.openWorkAndPersonal(run, app: app)
        let menu = try await run.step("read and use the Space name's menu", timeout: E2ETimeouts.step) {
            let titles = try app.spaceMenuTitles(in: page).map {
                $0 == "Profile/Delete Profile…!" ? "Profile/Delete Profile…" : $0
            }.filter {
                !$0.hasPrefix("Profile/") || Self.fixedProfileEntries.contains($0)
            }
            try app.chooseSpaceMenuItem(["Rename Space…"], in: page)
            let field = try await E2EWaits.value({ try app.sheetField(in: page) }, until: { $0?.text == "work" })
            try app.pressSheetKey(.escape, in: page)
            let after = try await SpaceNameTests.afterSheet(app, page) { _ in true }
            return (titles, field?.text ?? "no field", after)
        }
        run.check(
            name,
            passed: menu.0 == Self.expected && menu.1 == "work" && menu.2.closed
                && menu.2.spaces.spaces == ["work", "personal"],
            "menu=[\(menu.0.joined(separator: ","))] rename=\(menu.1) closed=\(menu.2.closed) \(menu.2.spaces)")
    }
}
