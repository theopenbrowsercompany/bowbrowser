import Foundation

/// Tests of sidebar folders: creating nested folders from the context menus, renaming in place, deleting with or
/// without their tabs, empty folders, dragging folders between levels and the zones, and folders' open or closed
/// state surviving a relaunch. Fixtures in E2E/Fixtures/sidebar/.
@MainActor
enum FoldersTests {
    static let all: [any E2ETest] = [FoldersTreeTest(), FoldersDeleteTest(), FoldersCollapseTest()]

    static func app(_ run: E2ERun) throws -> any E2EFoldersApp {
        guard let app = run.app as? any E2EFoldersApp else { throw E2EError("the app has no sidebar folders") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("sidebar/page.html?name=\(name)") }

    /// What `read` gives once `condition` holds, or what it gave last shortly before the step's limit. Checked once
    /// per run loop turn, as the sidebar changes on main thread tasks.
    static func wait<T>(_ read: () throws -> T, until condition: (T) -> Bool) async throws -> T {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while true {
            let value = try read()
            if condition(value) || Date() >= deadline { return value }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// The row of the first outline row titled `title`.
    static func row(_ title: String, in page: any E2EPage, app: any E2EFoldersApp) throws -> Int {
        guard let row = try app.sidebarOutline(of: page).firstIndex(of: title) else {
            throw E2EError("the sidebar has no row \"\(title)\": \(try app.sidebarOutline(of: page))")
        }
        return row
    }

    /// The outline once it reads `expected` (in `E2EOutlineRow.description` form joined by " | "), or as it read
    /// last.
    static func outline(_ app: any E2EFoldersApp, of page: any E2EPage, until expected: String) async throws -> String {
        try await wait({ try app.sidebarOutlineRows(of: page).map(\.description).joined(separator: " | ") }) {
            $0 == expected
        }
    }

    /// Starts and ends a rename of a new or existing folder: waits for the field to show `old`, types `new` and
    /// presses Return, then waits for a row titled `new`. Returns a problem, or nil.
    static func rename(
        from old: String, to new: String, in page: any E2EPage, app: any E2EFoldersApp
    ) async throws -> String? {
        let editing = try await wait({ try app.sidebarRenameText(in: page) }) { $0 == old }
        guard editing == old else { return "the rename field showed \(editing ?? "nothing"), not \(old)" }
        try app.typeSidebarRename(new, in: page)
        let outline = try await wait({ try app.sidebarOutline(of: page) }) { $0.contains(new) }
        guard outline.contains(new), try app.sidebarRenameText(in: page) == nil else {
            return "renaming \(old) to \(new) left \(outline)"
        }
        return nil
    }
}

/// Creates a folder "client" from the pinned section's menu, "project" inside it from its menu and "phase" inside
/// that, each named in the rename field the new folder starts, then drags tab A into "phase" and reads the outline
/// with each row's depth. Then renames "phase" by double clicking it and "client" from its menu.
struct FoldersTreeTest: E2ETest {
    let name = "folders.tree"
    let checks = ["folders.tree", "folders.rename"]

    func run(_ run: E2ERun) async throws {
        let app = try FoldersTests.app(run)
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(
                seeded: E2ESeed(spaces: [E2ESeedSpace("Work", today: [.tab("A", url: FoldersTests.url("A"))])]))
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let page = window.page
        var problems: [String] = []
        try await run.step("create nested folders", timeout: E2ETimeouts.step) {
            for (parent, folder) in [("pinned", "client"), ("client", "project"), ("project", "phase")] {
                try app.chooseSidebarMenuItem(
                    "New Folder", row: try FoldersTests.row(parent, in: page, app: app), in: page)
                if let problem = try await FoldersTests.rename(from: "New Folder", to: folder, in: page, app: app) {
                    problems.append(problem)
                    return
                }
            }
        }
        try await run.step("drag A into phase", timeout: E2ETimeouts.step) {
            try app.dragTab(page, onRow: try FoldersTests.row("phase", in: page, app: app), childIndex: -1)
        }
        let expected =
            "favorites | pinned | >client | >>project | >>>phase | >>>>A | divider | today"
        let outline = try await run.step("read the outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: page, until: expected)
        }
        let active = try app.sidebarRows(of: page).first(where: \.isActive)?.title
        if active != "A" { problems.append("active=\(active ?? "none")") }
        let passed = problems.isEmpty && outline == expected
        run.check(
            "folders.tree", passed: passed,
            passed ? "tree=client/project/phase/[A]" : "\(outline) \(problems.joined(separator: "; "))")

        var renames: [String] = []
        try await run.step("rename by double click", timeout: E2ETimeouts.step) {
            try app.doubleClickSidebarRow(try FoldersTests.row("phase", in: page, app: app), in: page)
            if let problem = try await FoldersTests.rename(from: "phase", to: "Q3", in: page, app: app) {
                renames.append(problem)
            }
        }
        try await run.step("rename from the menu", timeout: E2ETimeouts.step) {
            try app.chooseSidebarMenuItem(
                "Rename Folder", row: try FoldersTests.row("client", in: page, app: app), in: page)
            if let problem = try await FoldersTests.rename(from: "client", to: "acme", in: page, app: app) {
                renames.append(problem)
            }
        }
        let renamed = "favorites | pinned | >acme | >>project | >>>Q3 | >>>>A | divider | today"
        let after = try await run.step("read the renamed outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: page, until: renamed)
        }
        run.check(
            "folders.rename", passed: renames.isEmpty && after == renamed,
            renames.isEmpty && after == renamed
                ? "double-click phase=Q3 menu client=acme" : "\(after) \(renames.joined(separator: "; "))")
    }
}

/// Seeds pinned P1, folder Outer holding P3 and folder Inner (holding P2), and an empty folder. Checks the empty
/// folder is listed with a plain "Delete Folder"; that "Delete Folder and Tabs…" on Inner asks first, Cancel
/// keeping it and Delete removing it with P2; and that "Delete Folder, Keep Tabs" on Outer leaves P3 in its place.
struct FoldersDeleteTest: E2ETest {
    let name = "folders.delete"
    let checks = ["folders.empty", "folders.delete-tabs", "folders.delete-keep"]

    func run(_ run: E2ERun) async throws {
        let app = try FoldersTests.app(run)
        let url = FoldersTests.url
        let seed = E2ESeed(spaces: [
            E2ESeedSpace(
                "Work",
                pinned: [
                    .tab("P1", url: url("P1")),
                    .folder("Outer", [.tab("P3", url: url("P3")), .folder("Inner", [.tab("P2", url: url("P2"))])]),
                    .folder("Empty", []),
                ],
                today: [.tab("T1", url: url("T1"))])
        ])
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let page = window.page
        let seeded = "favorites | pinned | >P1 | >Outer | >>P3 | >>Inner | >>>P2 | >Empty | divider | today | >T1"
        let outline = try await run.step("read the seeded outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: page, until: seeded)
        }
        let emptyMenu = try await run.step("read the empty folder's menu", timeout: E2ETimeouts.step) {
            try app.sidebarMenuTitles(row: try FoldersTests.row("Empty", in: page, app: app), in: page)
        }
        let plainDelete = ["New Folder", "Rename Folder", "-", "Delete Folder"]
        run.check(
            "folders.empty", passed: outline == seeded && emptyMenu == plainDelete,
            "Empty=shown menu=[\(emptyMenu.joined(separator: ","))]\(outline == seeded ? "" : " outline=\(outline)")")

        var problems: [String] = []
        let sheet = try await run.step("ask before deleting Inner and its tabs", timeout: E2ETimeouts.step) {
            try app.chooseSidebarMenuItem(
                "Delete Folder and Tabs…", row: try FoldersTests.row("Inner", in: page, app: app), in: page)
            return try await FoldersTests.wait({ try app.sidebarSheet(in: page) }) { $0 != nil }
        }
        try await run.step("cancel", timeout: E2ETimeouts.step) {
            guard sheet != nil else { return problems.append("no sheet asked") }
            try app.clickSheetButton("Cancel", in: page)
            let gone = try await FoldersTests.wait({ try app.sidebarSheet(in: page) }) { $0 == nil }
            if gone != nil { problems.append("the sheet stayed after Cancel") }
            if try app.sidebarOutline(of: page).contains("Inner") == false {
                problems.append("Cancel deleted Inner")
            }
        }
        let deletedAll = "favorites | pinned | >P1 | >Outer | >>P3 | >Empty | divider | today | >T1"
        let afterDelete = try await run.step("delete Inner and its tabs", timeout: E2ETimeouts.step) {
            try app.chooseSidebarMenuItem(
                "Delete Folder and Tabs…", row: try FoldersTests.row("Inner", in: page, app: app), in: page)
            _ = try await FoldersTests.wait({ try app.sidebarSheet(in: page) }) { $0 != nil }
            try app.clickSheetButton("Delete", in: page)
            return try await FoldersTests.outline(app, of: page, until: deletedAll)
        }
        let asked = sheet.map(\.description) ?? "none"
        let texts = [
            "Delete \u{201C}Inner\u{201D} and its tabs?",
            "The folder and the 1 tab inside it will be removed from the sidebar.",
        ]
        // The sheet's buttons in any order: the order of its views is AppKit's.
        if sheet?.texts != texts || Set(sheet?.buttons ?? []) != ["Delete", "Cancel"] {
            problems.append("sheet=\(asked)")
        }
        run.check(
            "folders.delete-tabs", passed: problems.isEmpty && afterDelete == deletedAll,
            problems.isEmpty && afterDelete == deletedAll
                ? "asked=yes cancel=kept delete=Inner,P2 removed" : "\(afterDelete) \(problems.joined(separator: "; "))"
        )

        let kept = "favorites | pinned | >P1 | >P3 | >Empty | divider | today | >T1"
        let afterKeep = try await run.step("delete Outer, keeping its tabs", timeout: E2ETimeouts.step) {
            try app.chooseSidebarMenuItem(
                "Delete Folder, Keep Tabs", row: try FoldersTests.row("Outer", in: page, app: app), in: page)
            return try await FoldersTests.outline(app, of: page, until: kept)
        }
        let p3 = try window.itemIDs["P3"].flatMap { try app.storeEntry(id: $0, in: page) }
        run.check(
            "folders.delete-keep", passed: afterKeep == kept && p3?.parent == "pinned",
            afterKeep == kept && p3?.parent == "pinned"
                ? "P3=pinned pinned=[P1,P3,Empty]" : "\(afterKeep) P3=\(p3.map(\.description) ?? "gone")")
    }
}

/// Seeds pinned folders Open (holding P1), Shut (open, holding P2) and an empty folder, and a today folder Loose
/// holding L. Drags Loose into Open, which pins it inside a folder, closes Shut with its triangle, relaunches the
/// sidebar from its file and checks Shut comes back closed, Open open with Loose in it, and the empty folder kept.
struct FoldersCollapseTest: E2ETest {
    let name = "folders.collapse"
    let checks = ["folders.drag", "folders.collapse"]

    func run(_ run: E2ERun) async throws {
        let app = try FoldersTests.app(run)
        let url = FoldersTests.url
        let seed = E2ESeed(spaces: [
            E2ESeedSpace(
                "Work",
                pinned: [
                    .folder("Open", [.tab("P1", url: url("P1"))]), .folder("Shut", [.tab("P2", url: url("P2"))]),
                    .folder("Empty", []),
                ],
                today: [.folder("Loose", [.tab("L", url: url("L"))])])
        ])
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let page = window.page
        let seeded = "favorites | pinned | >Open | >>P1 | >Shut | >>P2 | >Empty | divider | today | >Loose | >>L"
        _ = try await run.step("read the seeded outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: page, until: seeded)
        }
        let dragged = "favorites | pinned | >Open | >>P1 | >>Loose | >>>L | >Shut | >>P2 | >Empty | divider | today"
        let afterDrag = try await run.step("drag Loose into Open", timeout: E2ETimeouts.step) {
            try app.dragSidebarRow(
                try FoldersTests.row("Loose", in: page, app: app),
                onRow: try FoldersTests.row("Open", in: page, app: app), childIndex: -1, in: page)
            return try await FoldersTests.outline(app, of: page, until: dragged)
        }
        let loose = try window.itemIDs["Loose"].flatMap { try app.storeEntry(id: $0, in: page) }
        let open = window.itemIDs["Open"]
        let dragPassed = afterDrag == dragged && loose?.parent == open && open != nil
        run.check(
            "folders.drag", passed: dragPassed,
            dragPassed ? "Loose=pinned parent=Open" : "\(afterDrag) Loose=\(loose.map(\.description) ?? "gone")")

        let closed = "favorites | pinned | >Open | >>P1 | >>Loose | >>>L | >Shut | >Empty | divider | today"
        let afterClose = try await run.step("close Shut", timeout: E2ETimeouts.step) {
            try app.clickSidebarDisclosure(row: try FoldersTests.row("Shut", in: page, app: app), in: page)
            return try await FoldersTests.outline(app, of: page, until: closed)
        }
        let relaunched = try await run.step("relaunch", timeout: E2ETimeouts.firstLoad) {
            try await app.relaunchSidebar(of: page)
        }
        let afterRelaunch = try await run.step("read the relaunched outline", timeout: E2ETimeouts.step) {
            try await FoldersTests.outline(app, of: relaunched.page, until: closed)
        }
        let passed = afterClose == closed && afterRelaunch == closed
        run.check(
            "folders.collapse", passed: passed,
            passed
                ? "relaunch: Shut=closed Open=open Empty=kept"
                : "before=\(afterClose) after=\(afterRelaunch)")
    }
}
