import Foundation

/// Tests of split view as a sidebar item: making a split from a tab's context menu or Add Split View, saving its
/// widths, taking a pane out with its close button, separating it, repairing broken splits on load and coming back
/// to a split after selecting another tab. Fixtures in E2E/Fixtures/split/.
@MainActor
enum SplitTests {
    static let all: [any E2ETest] = [
        SplitCreateTest(), SplitAddTest(), SplitResizeTest(), SplitRemoveTest(), SplitSeparateTest(),
        SplitRepairTest(), SplitReturnTest(),
    ]

    typealias App = E2ESplitApp & E2EFoldersApp & E2EPanesApp & E2EStoreSeedApp

    static func app(_ run: E2ERun) throws -> any App {
        guard let app = run.app as? any App else { throw E2EError("the app has no split views") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("split/\(name.lowercased()).html") }

    /// A seeded window whose today section holds tabs titled `names`, the first selected.
    static func window(_ names: [String], app: any App, extra: [E2ESeedItem] = []) async throws -> any E2EPage {
        let seed = E2ESeed(spaces: [E2ESeedSpace("Split", today: names.map { .tab($0, url: url($0)) } + extra)])
        let page = try await app.openWindow(seeded: seed).page
        _ = try await page.waitForLoad(after: 0)
        return page
    }

    /// The split state once `condition` holds, or as it was last.
    static func state(
        _ app: any App, of page: any E2EPage, until condition: (E2ESplitState) -> Bool
    ) async throws -> E2ESplitState {
        try await FoldersTests.wait(until: condition, read: { try app.splitState(of: page) })
    }

    /// Chooses "Open in Split View" on the row of tab `title`, with the active tab beside it, and waits for the
    /// panes to show `panes`.
    static func openInSplitView(
        _ title: String, panes: [String], app: any App, page: any E2EPage
    ) async throws -> E2ESplitState {
        let row = try FoldersTests.row(title, in: page, app: app)
        try app.chooseSidebarMenuItem("Open in Split View", row: row, in: page)
        let state = try await state(app, of: page) { $0.panes == panes }
        guard state.panes == panes else { throw E2EError("the split did not show: \(state)") }
        return state
    }

    static func approximately(_ actual: [Double], _ expected: [Double], tolerance: Double = 0.01) -> Bool {
        actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }
    }
}

/// Tabs A and B with A selected: B's "Open in Split View" makes a split of A and B, saved as the today section's
/// one item, shown as two panes with B focused and a close button on each.
struct SplitCreateTest: E2ETest {
    let name = "split"
    let checks = ["split"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let page = try await run.step("open tabs A and B", timeout: E2ETimeouts.firstLoad) {
            try await SplitTests.window(["A", "B"], app: app)
        }
        let state = try await run.step("open B in split view", timeout: E2ETimeouts.firstLoad) {
            _ = try await SplitTests.openInSplitView("B", panes: ["A", "B"], app: app, page: page)
            return try await SplitTests.state(app, of: page) { $0.closeButtons == 2 && $0.splits.count == 1 }
        }
        let passed =
            state.panes == ["A", "B"] && state.todayItems == 1 && state.splits == [["A", "B"]]
            && state.focusedIndex == 1 && state.activeTitle == "B" && state.splitFocus == ["B"]
            && state.closeButtons == 2
        run.check(
            "split", passed: passed,
            passed ? "panes=[\(state.panes.joined(separator: ","))] items=\(state.todayItems)" : "\(state)")
    }
}

/// Tab A alone: View > Add Split View (Cmd+Shift+plus, Arc's shortcut) opens a new tab as a second pane beside A,
/// focused, saved as one split.
struct SplitAddTest: E2ETest {
    let name = "split.add"
    let checks = ["split.add"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        guard let menu = run.app as? any E2EMenuApp else { throw E2EError("the app has no menus") }
        let page = try await run.step("open tab A", timeout: E2ETimeouts.firstLoad) {
            try await SplitTests.window(["A"], app: app)
        }
        let state = try await run.step("choose Add Split View", timeout: E2ETimeouts.firstLoad) {
            try menu.chooseMenuItem(key: "+", modifiers: [.command, .shift], in: page)
            return try await SplitTests.state(app, of: page) { $0.panes.count == 2 && $0.splits.count == 1 }
        }
        run.check(
            "split.add",
            passed: state.panes.count == 2 && state.panes.first == "A" && state.focusedIndex == 1
                && state.splits.count == 1 && state.splits.first?.first == "A" && state.todayItems == 1,
            "\(state)")
    }
}

/// A split of A and B: dragging the divider to 70% saves widths of 0.7 and 0.3 in the split, and after the sidebar
/// is read back from its file the split shows again at those widths.
struct SplitResizeTest: E2ETest {
    let name = "split.resize"
    let checks = ["split.resize.saved", "split.resize.reloaded"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        guard let store = run.app as? any E2EStoreApp else { throw E2EError("the app has no sidebar store") }
        let page = try await run.step("open a split of A and B", timeout: E2ETimeouts.firstLoad) {
            let page = try await SplitTests.window(["A", "B"], app: app)
            _ = try await SplitTests.openInSplitView("B", panes: ["A", "B"], app: app, page: page)
            return page
        }
        let saved = try await run.step("drag the divider to 70%", timeout: E2ETimeouts.step) {
            try app.dragPaneDivider(0, to: 0.7, besides: page)
            return try await SplitTests.state(app, of: page) {
                SplitTests.approximately($0.splitWidths.first ?? [], [0.7, 0.3])
            }
        }
        run.check(
            "split.resize.saved",
            passed: SplitTests.approximately(saved.splitWidths.first ?? [], [0.7, 0.3]) && saved.panes == ["A", "B"],
            "\(saved)")

        let reloaded = try await run.step("read the sidebar back from its file", timeout: E2ETimeouts.firstLoad) {
            let relaunched = try await store.relaunchSidebar(of: page).page
            let state = try await SplitTests.state(app, of: relaunched) { $0.panes == ["A", "B"] }
            let panes = try await FoldersTests.wait(
                until: { $0.frames.count == 2 },
                read: { try app.panes(besides: relaunched) })
            return (state, panes)
        }
        let widths = reloaded.1.frames.map { Double($0.width) }
        let share = widths.count == 2 ? widths[0] / (widths[0] + widths[1]) : 0
        run.check(
            "split.resize.reloaded",
            passed: reloaded.0.panes == ["A", "B"]
                && SplitTests.approximately(reloaded.0.splitWidths.first ?? [], [0.7, 0.3])
                && abs(share - 0.7) < 0.01,
            "share=\(share) \(reloaded.0)")
    }
}

/// A split of A and B with the keyboard in B's page: A's pane close button takes A out of the split, which leaves
/// B and A as plain tabs (no tab closes), B shown alone with the keyboard still in its page.
struct SplitRemoveTest: E2ETest {
    let name = "split.remove"
    let checks = ["split.remove", "split.remove.keyboard"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let page = try await run.step("open a split of A and B", timeout: E2ETimeouts.firstLoad) {
            let page = try await SplitTests.window(["A", "B", "C"], app: app)
            _ = try await SplitTests.openInSplitView("B", panes: ["A", "B"], app: app, page: page)
            guard try app.focusPane(at: 1, besides: page),
                try await SplitTests.state(app, of: page, until: \.keyboardInFocused).keyboardInFocused
            else { throw E2EError("B's page did not get the keyboard: \(try app.splitState(of: page))") }
            return page
        }
        let state = try await run.step("press A's pane close button", timeout: E2ETimeouts.step) {
            try app.clickPaneCloseButton(at: 0, besides: page)
            return try await SplitTests.state(app, of: page) { $0.panes == ["B"] && $0.splits.isEmpty }
        }
        run.check(
            "split.remove",
            passed: state.panes == ["B"] && state.splits.isEmpty && state.activeTitle == "B"
                && state.today == ["B", "A", "C"] && state.closeButtons == 0,
            "\(state)")
        run.check("split.remove.keyboard", passed: state.keyboardInFocused, "\(state)")
    }
}

/// A split of A and B: while a confirmation sheet is up, a click in the other pane leaves the active tab as it was;
/// then the split row's "Separate All Tabs" turns it back into tabs A and B in its place, B shown alone.
struct SplitSeparateTest: E2ETest {
    let name = "split.separate"
    let checks = ["split.sheet", "split.separate"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let page = try await run.step("open a split of A and B", timeout: E2ETimeouts.firstLoad) {
            let page = try await SplitTests.window(
                ["A", "B", "C"], app: app, extra: [.folder("F", [.tab("D", url: SplitTests.url("D"))])])
            _ = try await SplitTests.openInSplitView("B", panes: ["A", "B"], app: app, page: page)
            return page
        }
        let sheet = try await run.step("click pane A under a sheet", timeout: E2ETimeouts.step) {
            try app.chooseSidebarMenuItem(
                "Delete Folder and Tabs…", row: try FoldersTests.row("F", in: page, app: app), in: page)
            guard try await FoldersTests.wait(until: { $0 != nil }, read: { try app.sidebarSheet(in: page) }) != nil
            else { throw E2EError("no confirmation sheet showed") }
            try app.clickPane(at: 0, besides: page)
            let state = try app.splitState(of: page)
            try app.clickSheetButton("Cancel", in: page)
            return state
        }
        run.check(
            "split.sheet", passed: sheet.activeTitle == "B" && sheet.focusedIndex == 1 && sheet.panes == ["A", "B"],
            "\(sheet)")

        let state = try await run.step("separate all tabs", timeout: E2ETimeouts.step) {
            _ = try await FoldersTests.wait(until: { $0 == nil }, read: { try app.sidebarSheet(in: page) })
            let row = try FoldersTests.row("Split View", in: page, app: app)
            try app.chooseSidebarMenuItem("Separate All Tabs", row: row, in: page)
            return try await SplitTests.state(app, of: page) { $0.splits.isEmpty && $0.panes.count == 1 }
        }
        run.check(
            "split.separate",
            passed: state.splits.isEmpty && state.panes == ["B"] && state.activeTitle == "B"
                && state.today == ["A", "B", "C", "F"] && state.closeButtons == 0,
            "\(state)")
    }
}

/// A sidebar file holding a split with no tabs and a split holding only tab B opens repaired: the empty split is
/// gone, B is a plain tab in its split's place, and no split shows.
struct SplitRepairTest: E2ETest {
    let name = "split.repair"
    let checks = ["split.repair"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let page = try await run.step("open tabs A, B and C", timeout: E2ETimeouts.firstLoad) {
            try await SplitTests.window(["A", "B", "C"], app: app)
        }
        let state = try await run.step("reopen with broken splits", timeout: E2ETimeouts.firstLoad) {
            let reopened = try await app.relaunchWithBrokenSplits(of: page, lone: "B")
            return (try app.splitState(of: reopened), try app.sidebarOutline(of: reopened))
        }
        run.check(
            "split.repair",
            passed: state.0.splits.isEmpty && state.0.today == ["B", "A", "C"] && state.0.itemCount == 3
                && state.0.panes.count == 1 && !state.1.contains("Split View"),
            "\(state.0) outline=\(state.1)")
    }
}

/// A split of A and B with A focused: selecting C shows C alone, and clicking the split's row brings both panes back
/// with A focused again.
struct SplitReturnTest: E2ETest {
    let name = "split.return"
    let checks = ["split.return.away", "split.return"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let page = try await run.step("open a split of A and B, A focused", timeout: E2ETimeouts.firstLoad) {
            let page = try await SplitTests.window(["A", "B", "C"], app: app)
            _ = try await SplitTests.openInSplitView("B", panes: ["A", "B"], app: app, page: page)
            guard try app.focusPane(at: 0, besides: page) else { throw E2EError("pane A did not take focus") }
            return page
        }
        let away = try await run.step("select C", timeout: E2ETimeouts.firstLoad) {
            try app.clickSplitSidebarRow(try FoldersTests.row("C", in: page, app: app), in: page)
            return try await SplitTests.state(app, of: page) { $0.panes == ["C"] }
        }
        run.check(
            "split.return.away",
            passed: away.panes == ["C"] && away.activeTitle == "C" && away.splitFocus == ["A"]
                && away.closeButtons == 0,
            "\(away)")
        let back = try await run.step("click the split's row", timeout: E2ETimeouts.step) {
            try app.clickSplitSidebarRow(try FoldersTests.row("Split View", in: page, app: app), in: page)
            return try await SplitTests.state(app, of: page) { $0.panes == ["A", "B"] }
        }
        run.check(
            "split.return",
            passed: back.panes == ["A", "B"] && back.focusedIndex == 0 && back.activeTitle == "A"
                && back.closeButtons == 2,
            "\(back)")
    }
}
