import Foundation

/// Tests of basic page behaviors: zoom per site from the keys and the View menu, the crashed tab page and its Reload
/// button, and Copy Image from the context menu. Fixtures in E2E/Fixtures/page/.
@MainActor
enum PageTests {
    static let all: [any E2ETest] = [PageZoomTest(), PageCrashTest(), PageCopyImageTest()]

    typealias App = any E2EPageBehaviorApp & E2EMenuApp & E2EContextMenuApp

    static func app(_ run: E2ERun) throws -> App {
        guard let app = run.app as? App else { throw E2EError("the app has no page behavior hooks") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("page/\(name)") }

    /// Waits until `condition` holds, or the step's wait budget runs out, and returns whether it held.
    static func until(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try condition()
    }

    /// The zoom factor of `percent`, to compare with what the engine reports with a tolerance.
    static func level(_ percent: Int) -> Double {
        Double(percent) / 100
    }
}

/// Cmd+= zooms the page in (the page never sees the key), the View menu's Zoom In, Zoom Out and Actual Size and the
/// Cmd+minus and Cmd+0 keys step through the preset sizes, and another site keeps its own zoom.
struct PageZoomTest: E2ETest {
    let name = "page.zoom"
    let tags = ["smoke"]
    let checks = ["page.zoom.keys", "page.zoom.menu", "page.zoom.site"]

    func run(_ run: E2ERun) async throws {
        let app = try PageTests.app(run)
        let page = try await run.step("open the page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: PageTests.url("page.html"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        func level(_ page: any E2EPage) throws -> Double { try app.zoomFactor(of: page) }
        func waitForLevel(_ percent: Int, _ page: any E2EPage) async throws -> Bool {
            try await PageTests.until { abs(try level(page) - PageTests.level(percent)) < 0.001 }
        }

        let keys = try await run.step("zoom with the keys", timeout: E2ETimeouts.step * 2) {
            // Cmd+= (110%), Cmd+= (125%), Cmd+minus (110%), Cmd+0 (100%), as they arrive at the page.
            var steps: [Bool] = []
            try await page.press(letter: "=", macKeyCode: 24, modifiers: .command)
            steps.append(try await waitForLevel(110, page))
            try await page.press(letter: "=", macKeyCode: 24, modifiers: .command)
            steps.append(try await waitForLevel(125, page))
            try await page.press(letter: "-", macKeyCode: 27, modifiers: .command)
            steps.append(try await waitForLevel(110, page))
            try await page.press(letter: "0", macKeyCode: 29, modifiers: .command)
            steps.append(try await waitForLevel(100, page))
            // A key the app does not claim still reaches the page, so a key the page saw would show up here.
            try await page.press(letter: "j", macKeyCode: 38, modifiers: [])
            try await E2EWaits.until(page, "window.keyDowns.some(k => k === 'j')")
            let seen = try await page.evaluate("window.keyDowns") as? [String] ?? []
            return (steps, seen)
        }
        run.check(
            "page.zoom.keys",
            passed: keys.0 == [true, true, true, true] && keys.1 == ["j"],
            "steps=\(keys.0) page-keys=\(keys.1)")

        let menu = try await run.step("zoom from the View menu", timeout: E2ETimeouts.step * 2) {
            var steps: [Bool] = []
            try app.chooseMenuItem(key: "=", modifiers: .command, in: page)
            steps.append(try await waitForLevel(110, page))
            try app.chooseMenuItem(key: "-", modifiers: .command, in: page)
            try app.chooseMenuItem(key: "-", modifiers: .command, in: page)
            steps.append(try await waitForLevel(90, page))
            try app.chooseMenuItem(key: "0", modifiers: .command, in: page)
            steps.append(try await waitForLevel(100, page))
            return steps
        }
        run.check("page.zoom.menu", passed: menu == [true, true, true], "steps=\(menu)")

        let site = try await run.step("another site keeps its zoom", timeout: E2ETimeouts.firstLoad) {
            // The first site is at 110%; a page on another site opens at 100% and zooms out on its own.
            try app.chooseMenuItem(key: "=", modifiers: .command, in: page)
            guard try await waitForLevel(110, page) else { throw E2EError("the first site never zoomed in") }
            let other = try app.openTab(at: URL(string: "https://other.test/page.html")!, besides: page, select: true)
            _ = try? await other.waitForLoad(after: 0)
            let opened = try level(other)
            try app.chooseMenuItem(key: "-", modifiers: .command, in: other)
            guard try await waitForLevel(90, other) else { throw E2EError("the other site never zoomed out") }
            return (opened, try level(page), try level(other))
        }
        run.check(
            "page.zoom.site",
            passed: abs(site.0 - 1) < 0.001 && abs(site.1 - PageTests.level(110)) < 0.001
                && abs(site.2 - PageTests.level(90)) < 0.001,
            "other-opened=\(site.0) first=\(site.1) other=\(site.2)")
    }
}

/// A page whose renderer ends shows "This page crashed" with a Reload button over the page area, and Reload brings
/// the page back and takes the overlay away. The page crashes by loading chrome://crash, which Chromium handles for a
/// load the app starts (no page can reach it), so Chromium's crash reporter also writes a report: Debug builds turn it
/// on with App/Debug/crash_reporter.cfg and no upload server, and CEF keeps its database in the root data folder
/// itself (`<run>/profile`). Crashpad writes a report in `new/` and moves it to `pending/` (or `completed/`) once
/// whole, so only those count as written. A run that passes removes its profile, so the test copies the report to
/// `<run>/crash-reports/`, where it outlives the run.
struct PageCrashTest: E2ETest {
    let name = "page.crash"
    let tags = ["smoke"]
    let checks = ["page.crash.overlay", "page.crash.report", "page.crash.reload"]
    var expectsRendererCrash: Bool { true }

    func run(_ run: E2ERun) async throws {
        let app = try PageTests.app(run)
        let page = try await run.step("open the page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: PageTests.url("page.html"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let before = try await page.string("window.loadId")
        // Every report already in the database, unfinished ones included, by file name (the report's ID), which stays
        // the same when Crashpad moves a report between its folders.
        let database = run.dataDirectory
        let earlier = Set(Self.reports(in: database, states: ["new", "pending", "completed"]).map(\.lastPathComponent))
        let crashed = try await run.step("load chrome://crash", timeout: E2ETimeouts.firstLoad) {
            guard let crashURL = URL(string: "chrome://crash") else { throw E2EError("no chrome://crash URL") }
            try page.load(crashURL)
            guard try await PageTests.until({ try app.crashedPage(of: page).isShown }) else {
                throw E2EError("the crashed tab page never showed")
            }
            return try app.crashedPage(of: page)
        }
        run.check(
            "page.crash.overlay",
            passed: crashed.isShown && crashed.message == "This page crashed" && crashed.buttonTitle == "Reload"
                && crashed.buttonReachable,
            "\(crashed)")

        let kept = try await run.step("keep the crash report", timeout: E2ETimeouts.firstLoad) { () -> URL? in
            let folder = run.outputDirectory.appendingPathComponent("crash-reports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A copy can fail when Crashpad moves the report between its folders meanwhile; the next try finds it.
            var copied: URL?
            try await E2EWaits.until {
                let whole = Self.reports(in: database, states: ["pending", "completed"])
                guard let report = whole.first(where: { !earlier.contains($0.lastPathComponent) }) else { return false }
                let copy = folder.appendingPathComponent(report.lastPathComponent)
                try? FileManager.default.removeItem(at: copy)
                guard (try? FileManager.default.copyItem(at: report, to: copy)) != nil else { return false }
                copied = copy
                return true
            }
            return copied
        }
        // A minidump starts with the signature "MDMP".
        let data = kept.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let minidump = data.prefix(4) == Data("MDMP".utf8)
        run.check(
            "page.crash.report", passed: minidump && data.count > 4,
            "report=\(kept?.path ?? "none") bytes=\(data.count) minidump=\(minidump) database=\(database.path) "
                + "earlier=\(earlier.count)")

        let loads = page.finishedLoads
        let reloaded = try await run.step("press Reload", timeout: E2ETimeouts.firstLoad) {
            try app.clickCrashedReload(of: page)
            _ = try await page.waitForLoad(after: loads)
            let hidden = try await PageTests.until { try !app.crashedPage(of: page).isShown }
            let after = try await page.string("window.loadId")
            return (hidden, after)
        }
        run.check(
            "page.crash.reload", passed: reloaded.0 && !reloaded.1.isEmpty && reloaded.1 != before,
            "overlay-hidden=\(reloaded.0) page-reloaded=\(reloaded.1 != before)")
    }

    /// The minidumps in the given folders of Crashpad's database at `database`.
    private static func reports(in database: URL, states: [String]) -> [URL] {
        states.flatMap { state -> [URL] in
            let folder = database.appendingPathComponent(state, isDirectory: true)
            let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            return (files ?? []).filter { $0.pathExtension == "dmp" }
        }
    }
}

/// Copy Image from an image's context menu puts the image itself, not its address, on the pasteboard.
struct PageCopyImageTest: E2ETest {
    let name = "page.copy-image"
    let tags = ["smoke"]

    func run(_ run: E2ERun) async throws {
        let app = try PageTests.app(run)
        let page = try await run.step("open the page", timeout: E2ETimeouts.firstLoad) {
            let page = try await app.openWindow(at: PageTests.url("page.html"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let board = try app.usePrivateImagePasteboard(of: page)
        defer { board.release() }
        let result = try await run.step("copy the image", timeout: E2ETimeouts.firstLoad) {
            try await E2EWaits.until(page, "document.getElementById('image').complete")
            try app.chooseContextMenuItem("Copy Image")
            let before = board.changeCount
            try await page.rightClick("#image")
            guard try await PageTests.until({ board.changeCount != before }) else {
                throw E2EError("nothing was copied: menus=\(try app.contextMenus().map(\.items))")
            }
            return (try app.contextMenus().first?.items ?? [], board.imagePixelSize, board.string)
        }
        run.check(
            name,
            passed: result.1 == CGSize(width: 32, height: 32) && result.2 == nil
                && result.0.contains("Copy Image") && result.0.contains("Copy Image Address"),
            "size=\(result.1.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none") string=\(result.2 ?? "none") "
                + "items=\(result.0)")
    }
}
