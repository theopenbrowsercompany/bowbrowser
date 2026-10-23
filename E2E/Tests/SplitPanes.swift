import Foundation

/// Tests of split view's panes as a person uses them: stacked panes from Add Top Split and Add Bottom Split, a
/// divider drag saved once when it ends, Add Split View from a pinned tab, and the page UI each pane keeps for itself
/// (the permission prompt, the crashed page, the find bar and page dialogs), anchored to its own pane rather than the
/// focused one or the whole page area. Fixtures in E2E/Fixtures/split/, and the permissions, page and dialogs areas'
/// pages for what those pages ask.
@MainActor
enum SplitPanesTests {
    static let all: [any E2ETest] = [
        SplitStackedTest(), SplitResizeOnceTest(), SplitAddPinnedTest(), SplitPermissionPaneTest(),
        SplitCrashPaneTest(), SplitFindPaneTest(), SplitDialogPaneTest(),
    ]

    typealias App = SplitTests.App

    /// Opens a window on `first`, then `second` in a tab beside it, both loaded, and shows them as two panes side by
    /// side with the first focused.
    static func twoPanes(_ first: URL, _ second: URL, app: any App, run: E2ERun) async throws
        -> (any E2EPage, any E2EPage)
    {
        try await run.step("show two panes", timeout: E2ETimeouts.firstLoad) {
            let a = try await run.app.openWindow(at: first)
            _ = try await a.waitForLoad(after: 0)
            let b = try run.app.openTab(at: second, besides: a, select: false)
            _ = try await b.waitForLoad(after: 0)
            guard try app.showPanes([a, b], focused: a, fractions: nil) else {
                throw E2EError("the two panes did not show: \(try app.panes(besides: a))")
            }
            return (a, b)
        }
    }

    /// The overlays once `condition` holds, or as they were last.
    static func overlays(
        _ app: any App, besides page: any E2EPage, until condition: (E2EPaneOverlays) -> Bool
    ) async throws -> E2EPaneOverlays {
        try await FoldersTests.wait(until: condition, read: { try app.paneOverlays(besides: page) })
    }

    /// Whether `frames` sit stacked top to bottom (window coordinates, so the first is highest), each the full width.
    static func stacked(_ frames: [CGRect]) -> Bool {
        guard let first = frames.first else { return false }
        let fullWidth = frames.allSatisfy { abs($0.minX - first.minX) < 1 && abs($0.width - first.width) < 1 }
        let ordered = zip(frames, frames.dropFirst()).allSatisfy { $0.minY >= $1.maxY - 0.5 && $0.minY - $1.maxY < 3 }
        return fullWidth && ordered
    }
}

/// Tab A alone: View > Add Bottom Split opens a new tab D below A, and Add Top Split then opens C above them, in one
/// stacked split shown top to bottom C, A, D, each the full width of the page area.
struct SplitStackedTest: E2ETest {
    let name = "split.stacked"
    let checks = ["split.stacked", "split.stacked.top"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let page = try await run.step("open tab A", timeout: E2ETimeouts.firstLoad) {
            try await SplitTests.window(["A"], app: app)
        }
        let bottom = try await run.step("choose Add Bottom Split", timeout: E2ETimeouts.firstLoad) {
            try app.setNewTabURL(SplitTests.url("D"), of: page)
            try app.chooseStackedSplit(top: false, in: page)
            let state = try await SplitTests.state(app, of: page) { $0.panes == ["A", "D"] }
            return (state, try app.paneOverlays(besides: page))
        }
        run.check(
            "split.stacked",
            passed: bottom.0.panes == ["A", "D"] && bottom.0.splits == [["A", "D"]]
                && bottom.0.splitOrientations == ["vertical"] && bottom.0.focusedIndex == 1
                && bottom.0.activeTitle == "D" && SplitPanesTests.stacked(bottom.1.panes),
            "\(bottom.0) \(bottom.1)")

        let top = try await run.step("choose Add Top Split", timeout: E2ETimeouts.firstLoad) {
            try app.setNewTabURL(SplitTests.url("C"), of: page)
            try app.chooseStackedSplit(top: true, in: page)
            let state = try await SplitTests.state(app, of: page) { $0.panes == ["C", "A", "D"] }
            return (state, try app.paneOverlays(besides: page))
        }
        run.check(
            "split.stacked.top",
            passed: top.0.panes == ["C", "A", "D"] && top.0.splits == [["C", "A", "D"]]
                && top.0.splitOrientations == ["vertical"] && top.0.activeTitle == "C" && top.0.closeButtons == 3
                && SplitPanesTests.stacked(top.1.panes),
            "\(top.0) \(top.1)")
    }
}

/// A split of A and B: pressing on the divider and moving it in two steps leaves the saved widths as they were while
/// the panes follow the drag, and letting go saves the widths it ended at, once.
struct SplitResizeOnceTest: E2ETest {
    let name = "split.resize.once"
    let checks = ["split.resize.once"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let page = try await run.step("open a split of A and B", timeout: E2ETimeouts.firstLoad) {
            let page = try await SplitTests.window(["A", "B"], app: app)
            _ = try await SplitTests.openInSplitView("B", panes: ["A", "B"], app: app, page: page)
            return page
        }
        let drag = try await run.step("drag the divider in two steps", timeout: E2ETimeouts.step) {
            try app.pressPaneDivider(besides: page)
            try app.movePaneDivider(0, to: 0.6, besides: page)
            let first = try app.splitState(of: page)
            try app.movePaneDivider(0, to: 0.7, besides: page)
            let second = try app.splitState(of: page)
            let panes = try app.panes(besides: page)
            try app.releasePaneDivider(besides: page)
            let saved = try await SplitTests.state(app, of: page) {
                SplitTests.approximately($0.splitWidths.first ?? [], [0.7, 0.3])
            }
            return (first, second, panes, saved)
        }
        let widths = drag.2.frames.map { Double($0.width) }
        let share = widths.count == 2 ? widths[0] / (widths[0] + widths[1]) : 0
        let unsavedWhileDragging = [drag.0, drag.1].allSatisfy {
            SplitTests.approximately($0.splitWidths.first ?? [], [0.5, 0.5])
        }
        run.check(
            "split.resize.once",
            passed: unsavedWhileDragging && abs(share - 0.7) < 0.01
                && SplitTests.approximately(drag.3.splitWidths.first ?? [], [0.7, 0.3]),
            "during=\(drag.0.splitWidths),\(drag.1.splitWidths) share=\(share) after=\(drag.3.splitWidths)")
    }
}

/// Pinned tab A selected: Add Split View (Cmd+Shift+plus) opens a new tab D as a pane beside it, and the split of A
/// and D takes A's place in the pinned section; today keeps only B.
struct SplitAddPinnedTest: E2ETest {
    let name = "split.add_pinned"
    let checks = ["split.add_pinned"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        guard let menu = run.app as? any E2EMenuApp else { throw E2EError("the app has no menus") }
        let page = try await run.step("select pinned tab A", timeout: E2ETimeouts.firstLoad) {
            let seed = E2ESeed(spaces: [
                E2ESeedSpace(
                    "Split", pinned: [.tab("A", url: SplitTests.url("A"))], today: [.tab("B", url: SplitTests.url("B"))]
                )
            ])
            let page = try await app.openWindow(seeded: seed).page
            _ = try await page.waitForLoad(after: 0)
            try app.clickSplitSidebarRow(try FoldersTests.row("A", in: page, app: app), in: page)
            let state = try await SplitTests.state(app, of: page) { $0.activeTitle == "A" && $0.panes == ["A"] }
            guard state.activeTitle == "A" else { throw E2EError("pinned tab A is not selected: \(state)") }
            return page
        }
        let state = try await run.step("choose Add Split View", timeout: E2ETimeouts.firstLoad) {
            try app.setNewTabURL(SplitTests.url("D"), of: page)
            try menu.chooseMenuItem(key: "+", modifiers: [.command, .shift], in: page)
            return try await SplitTests.state(app, of: page) { $0.panes == ["A", "D"] && $0.splits.count == 1 }
        }
        run.check(
            "split.add_pinned",
            passed: state.panes == ["A", "D"] && state.splits == [["A", "D"]] && state.pinned == ["Split View"]
                && state.today == ["B"] && state.activeTitle == "D" && state.focusedIndex == 1,
            "\(state)")
    }
}

/// Two panes, A focused: B's page asks for the camera and its prompt shows at the top of B's pane while A keeps
/// focus; closing B with its prompt up takes the prompt away.
struct SplitPermissionPaneTest: E2ETest {
    let name = "split.permission_pane"
    let checks = ["split.permission_pane", "split.permission_pane.close"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let url = E2EFixture.url("permissions/index.html")
        let (a, b) = try await SplitPanesTests.twoPanes(url, url, app: app, run: run)
        let asked = try await run.step("ask for the camera in pane B", timeout: E2ETimeouts.step) {
            _ = try await b.evaluate("startCamera()")
            let prompt = try await b.waitForPermissionPrompt()
            let overlays = try await SplitPanesTests.overlays(app, besides: a) { $0.prompts.count == 1 }
            return (prompt, overlays, try app.panes(besides: a))
        }
        run.check(
            "split.permission_pane",
            passed: asked.0.kinds == ["camera"] && asked.1.prompts.count == 1
                && asked.1.pane(topOf: asked.1.prompts.first) == 1 && asked.2.focusedIndex == 0
                && a.permissionPrompt == nil && asked.1.windowOffScreen,
            "\(asked.1) focused=\(asked.2.focusedIndex)")

        let closed = try await run.step("close B with its prompt up", timeout: E2ETimeouts.step) {
            _ = try await run.app.closeTab(b)
            return try await SplitPanesTests.overlays(app, besides: a) { $0.prompts.isEmpty && $0.panes.count == 1 }
        }
        run.check(
            "split.permission_pane.close", passed: closed.prompts.isEmpty && closed.panes.count == 1, "\(closed)")
    }
}

/// Two panes, A focused: B's renderer ends and "This page crashed" covers B's pane only, with A still usable and
/// focused; B's Reload brings its page back.
struct SplitCrashPaneTest: E2ETest {
    let name = "split.crash_pane"
    let checks = ["split.crash_pane", "split.crash_pane.reload"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        guard let behavior = run.app as? any E2EPageBehaviorApp else { throw E2EError("the app has no crashed page") }
        let url = E2EFixture.url("page/page.html")
        let (a, b) = try await SplitPanesTests.twoPanes(url, url, app: app, run: run)
        let crashed = try await run.step("crash pane B", timeout: E2ETimeouts.firstLoad) {
            // The call never answers once the page is gone, so it is not waited for.
            let call = Task { _ = try? await b.devTools("Page.crash", [:]) }
            defer { call.cancel() }
            guard try await PageTests.until({ try behavior.crashedPage(of: b).isShown }) else {
                throw E2EError("the crashed tab page never showed")
            }
            return (
                try behavior.crashedPage(of: b), try behavior.crashedPage(of: a), try app.paneOverlays(besides: a),
                try app.panes(besides: a)
            )
        }
        let paneB = crashed.2.panes.count == 2 ? crashed.2.panes[1] : .zero
        let covers =
            abs(crashed.0.frame.minX - paneB.minX) < 1 && abs(crashed.0.frame.width - paneB.width) < 1
            && abs(crashed.0.frame.height - paneB.height) < 1
        run.check(
            "split.crash_pane",
            passed: crashed.0.isShown && crashed.0.buttonReachable && covers && !crashed.1.isShown
                && crashed.3.focusedIndex == 0,
            "B: \(crashed.0) A shown=\(crashed.1.isShown) \(crashed.2)")

        let loads = b.finishedLoads
        let reloaded = try await run.step("press Reload on pane B", timeout: E2ETimeouts.firstLoad) {
            try behavior.clickCrashedReload(of: b)
            _ = try await b.waitForLoad(after: loads)
            return try await PageTests.until { try !behavior.crashedPage(of: b).isShown }
        }
        run.check("split.crash_pane.reload", passed: reloaded, "overlay-hidden=\(reloaded)")
    }
}

/// Two panes, A focused on the left: Cmd+F opens the find bar at the top trailing corner of A's pane, not of the page
/// area, and it finds in A; focusing B closes it.
struct SplitFindPaneTest: E2ETest {
    let name = "split.find_pane"
    let checks = ["split.find_pane", "split.find_pane.focus"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let (a, _) = try await SplitPanesTests.twoPanes(
            SplitTests.url("A"), SplitTests.url("B"), app: app, run: run)
        let found = try await run.step("find in pane A", timeout: E2ETimeouts.step) {
            let bar = try a.openFindBar()
            try bar.type("fixture A")
            try await bar.waitForCount("1 of 1")
            return (bar.count, try app.paneOverlays(besides: a))
        }
        let paneA = found.1.panes.first ?? .zero
        let trailing = found.1.findBar.map { abs($0.maxX - (paneA.maxX - 16)) < 1.5 } ?? false
        run.check(
            "split.find_pane",
            passed: found.1.pane(topOf: found.1.findBar) == 0 && trailing && found.0 == "1 of 1",
            "count=\(found.0) \(found.1)")

        let focused = try await run.step("focus pane B", timeout: E2ETimeouts.step) {
            guard try app.focusPane(at: 1, besides: a) else { throw E2EError("pane B did not take focus") }
            return try await SplitPanesTests.overlays(app, besides: a) { $0.findBar == nil }
        }
        run.check("split.find_pane.focus", passed: focused.findBar == nil, "\(focused)")
    }
}

/// Two panes, A focused: a confirm from B comes up at once as a sheet dropping from the top of B's pane, with A still
/// focused and the window still off screen, and B gets the answer; a second confirm from B goes down when B closes.
struct SplitDialogPaneTest: E2ETest {
    let name = "split.dialog_pane"
    let checks = ["split.dialog_pane", "split.dialog_pane.close"]

    func run(_ run: E2ERun) async throws {
        let app = try SplitTests.app(run)
        let dialogs = try PageDialogsTests.dialogsApp(run)
        let (a, b) = try await SplitPanesTests.twoPanes(
            PageDialogsTests.url("A"), PageDialogsTests.url("B"), app: app, run: run)
        let up = try await run.step("confirm from pane B", timeout: E2ETimeouts.step) {
            try await PageDialogsTests.ask(b, "confirm", "from B")
            let dialog = try await PageDialogsTests.untilDialog(dialogs, besides: a)
            let overlays = try await SplitPanesTests.overlays(app, besides: a) { $0.sheet != nil }
            let focused = try app.panes(besides: a).focusedIndex
            try dialogs.answerPageDialog(besides: a, accept: true, text: nil)
            return (dialog, overlays, focused, try await PageDialogsTests.results(b, count: 1))
        }
        let paneB = up.1.panes.count == 2 ? up.1.panes[1] : .zero
        let centered =
            up.1.sheet.map { abs($0.midX - paneB.midX) < 2 } ?? false && up.1.pane(holding: up.1.sheet) == 1
        run.check(
            "split.dialog_pane",
            passed: up.0.message == "from B" && up.0.isAttached && centered && up.2 == 0 && up.1.windowOffScreen
                && up.3 == "confirm:true",
            "\(PageDialogsTests.describe(up.0)) \(up.1) focused=\(up.2) results=\(up.3)")

        let closed = try await run.step("close B with its dialog up", timeout: E2ETimeouts.step) {
            try await PageDialogsTests.ask(b, "confirm", "again")
            _ = try await PageDialogsTests.untilDialog(dialogs, besides: a)
            _ = try await run.app.closeTab(b)
            let gone = try await TabEdgesTests.until { try dialogs.pageDialog(besides: a) == nil }
            return (gone, try app.panes(besides: a))
        }
        run.check(
            "split.dialog_pane.close", passed: closed.0 && closed.1.titles.count == 1,
            "sheet-gone=\(closed.0) \(closed.1)")
    }
}
