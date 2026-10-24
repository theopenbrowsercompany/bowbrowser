import Foundation

/// Tests of downloads: saving into the downloads folder, numbering taken names, and pausing, resuming, cancelling
/// and clearing from the downloads window. Fixtures in E2E/Fixtures/downloads/.
@MainActor
enum DownloadsTests {
    static let all: [any E2ETest] = [
        DownloadsTest(), DownloadsTabClosedTest(), DownloadsParkedPageTest(), DownloadsWindowClosedTest(),
        DownloadsFooterButtonTest(),
    ]
}

/// Clicks the downloads button in the sidebar footer with the downloads window hidden: the window shows, a second
/// click leaves one window, and the button shows activity only while a download runs.
struct DownloadsFooterButtonTest: E2ETest {
    let name = "downloads.footer-button"
    let checks = ["downloads.footer-button", "downloads.footer-activity"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EDownloadsButtonApp else { throw E2EError("the app has no downloads button") }
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("downloads/index.html"))
        }
        try await run.step("load the fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }
        let earlier = Set(try await run.app.downloads().map(\.id))

        let hiddenBefore = try await run.step("hide the downloads window", timeout: E2ETimeouts.step) {
            try await app.hideDownloadsWindow()
            return app.visibleDownloadsWindowCount() == 0
        }
        let idle = try app.downloadsButtonShowsActivity(in: page)
        let counts = try await run.step("click the button", timeout: E2ETimeouts.step) {
            try app.clickDownloadsButton(in: page)
            _ = try await DownloadRows.poll("the downloads window showed") {
                app.visibleDownloadsWindowCount() == 1 ? true : nil
            }
            // Clicking again with the window open brings it forward: still one window.
            try app.clickDownloadsButton(in: page)
            return app.visibleDownloadsWindowCount()
        }
        run.check(
            "downloads.footer-button", passed: hiddenBefore && counts == 1,
            "hidden before=\(hiddenBefore) windows after two clicks=\(counts)")

        do {
            let (_, row) = try await run.step("start a download", timeout: E2ETimeouts.step) {
                try await DownloadRows.startInTab(
                    run, "_slow/320000/footer-button.bin", fileName: "footer-button.bin", besides: page,
                    except: earlier)
            }
            _ = try await run.step("button shows the download", timeout: E2ETimeouts.step) {
                try await DownloadRows.poll("the button showed activity") {
                    (try? app.downloadsButtonShowsActivity(in: page)) == true ? true : nil
                }
            }
            try await run.step("cancel the download", timeout: E2ETimeouts.step) {
                try await DownloadRows.cancelAndClear(run, row)
            }
            _ = try await run.step("button settles", timeout: E2ETimeouts.step) {
                try await DownloadRows.poll("the button stopped showing activity") {
                    (try? app.downloadsButtonShowsActivity(in: page)) == false ? true : nil
                }
            }
            run.check(
                "downloads.footer-activity", passed: !idle, "idle before=\(!idle) active while running, idle after")
        } catch {
            if error is CancellationError { throw error }
            if let error = error as? E2EError, error.reason == .testEnded { throw error }
            await DownloadRows.cleanUp(run, except: earlier)
            throw error
        }
    }
}

/// Opens a held download of known size in a second tab and closes that tab mid download: the fixture server sends
/// its first chunk and holds the rest until the test releases it, so the close provably comes first. The tab leaves
/// at once, but its browser stays alive, out of sight, so the download goes on to complete once released (CEF would
/// cancel it with the browser); while it runs its name stays held. The parked browser closes once the download ends,
/// which the runner's `e2e.isolation` check sees.
struct DownloadsTabClosedTest: E2ETest {
    let name = "downloads.tab-closed"
    let checks = ["downloads.tab-closed"]
    static let size: Int64 = 100_000
    /// The held download whose tab closes, and the second one of the same name that shows its name is taken.
    static let closedKey = "tab-closed"
    static let againKey = "tab-closed-again"

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("downloads/index.html"))
        }
        try await run.step("load the fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }

        let earlier = Set(try await run.app.downloads().map(\.id))
        let closing = try await run.step("start the download in a second tab and close it", timeout: E2ETimeouts.step) {
            let tab = try run.app.openTab(
                at: E2EFixture.heldDownload(key: Self.closedKey, bytes: Self.size, fileName: "tab-closed.bin"),
                besides: page, select: false)
            let row = try await waitFor(run, "the held download ran") {
                $0.first {
                    !earlier.contains($0.id) && $0.fileName == "tab-closed.bin" && $0.state == "inProgress"
                        && $0.receivedBytes > 0
                }
            }
            guard try await run.app.closeTab(tab) else { throw E2EError("the download's tab did not close") }
            // The tab closes for the app at once, while its download still runs: it does not wait for the end.
            let afterClose = try await run.app.downloads().first { $0.id == row.id }
            return (row, afterClose?.state ?? "none")
        }
        let (atClose, stateAfterClose) = closing
        guard atClose.receivedBytes < Self.size / 2, stateAfterClose == "inProgress" || stateAfterClose == "paused"
        else {
            run.check(
                name, passed: false,
                "the download got \(atClose.receivedBytes) bytes before its tab closed, then was \(stateAfterClose)")
            await DownloadRows.cleanUp(run, except: earlier)
            return
        }

        do {
            // While the closed tab's download runs, it holds its name: the same file again is numbered.
            let next = try await run.step("a second download of the same name is numbered", timeout: E2ETimeouts.step) {
                let again = try run.app.openTab(
                    at: E2EFixture.heldDownload(key: Self.againKey, bytes: Self.size, fileName: "tab-closed.bin"),
                    besides: page, select: false)
                let next = try await waitFor(run, "the second download ran with a path") {
                    $0.first {
                        !earlier.contains($0.id) && $0.id != atClose.id && $0.state == "inProgress"
                            && $0.path?.lastPathComponent.hasPrefix("tab-closed") == true
                    }
                }
                try await run.app.press(.cancelOrClear, of: next)
                _ = try await waitFor(run, "the second download was cancelled") { [id = next.id] in
                    $0.first { $0.id == id && $0.state == "cancelled" }
                }
                _ = try await run.app.closeTab(again)
                return next
            }

            // Only now may the closed tab's download finish. It outlives its tab and completes; any other end means
            // its browser was destroyed. Its end has a step of its own: the first download to complete in an app
            // process waits on Chromium's one-time cost in its final stage (after the last byte, before
            // the end), which takes over a second and under load several, and must not share a step with the second download above.
            let (done, size) = try await run.step(
                "release the download and wait for its end", timeout: E2ETimeouts.step
            ) {
                E2EFixture.releaseHeld(Self.closedKey)
                let done = try await waitFor(run, "the released download ended") {
                    [id = atClose.id] rows -> E2EDownload? in
                    guard let row = rows.first(where: { $0.id == id }) else { return nil }
                    return row.state == "inProgress" || row.state == "paused" ? nil : row
                }
                let size = done.path.flatMap {
                    ((try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? NSNumber)?.int64Value
                }
                return (done, size)
            }
            try await run.step("clear the ended download", timeout: E2ETimeouts.step) {
                try await run.app.press(.cancelOrClear, of: done)
                _ = try await waitFor(run, "the ended download was cleared") { rows in
                    rows.contains { $0.id == done.id } ? nil : rows
                }
            }

            let passed =
                done.state == "complete" && done.status.hasPrefix("Complete") && size == Self.size
                && done.fileName == "tab-closed.bin" && next.fileName == "tab-closed (1).bin"
            run.check(
                name,
                passed: passed,
                passed
                    ? "state=\(done.state) row=updated closed-while=\(stateAfterClose)"
                    : "state=\(done.state) row=updated status=\"\(done.status)\" size=\(size.map(String.init) ?? "none") file=\(done.fileName) next=\(next.fileName)"
            )
        } catch {
            if error is CancellationError { throw error }
            if let error = error as? E2EError, error.reason == .testEnded { throw error }
            await DownloadRows.cleanUp(run, except: earlier)
            throw error
        }
    }

    private func waitFor<T>(_ run: E2ERun, _ what: String, _ match: ([E2EDownload]) -> T?) async throws -> T {
        try await DownloadRows.waitFor(run, what, match)
    }
}

/// Download row helpers shared by the tests of closed tabs' downloads.
@MainActor
enum DownloadRows {
    /// Cancels any download the test started that is still running, then clears every row it added, so a failure
    /// leaves no row behind for later tests.
    static func cleanUp(_ run: E2ERun, except earlier: Set<String>) async {
        guard let rows = try? await run.app.downloads() else { return }
        for row in rows where !earlier.contains(row.id) && (row.state == "inProgress" || row.state == "paused") {
            try? await run.app.press(.cancelOrClear, of: row)
        }
        for _ in 0..<50 {
            guard let rows = try? await run.app.downloads() else { return }
            let left = rows.filter { !earlier.contains($0.id) }
            if left.isEmpty { return }
            for row in left where row.state != "inProgress" && row.state != "paused" {
                try? await run.app.press(.cancelOrClear, of: row)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Reads the downloads window until `match` returns a value, checking every 20 ms, and gives up shortly before
    /// the step's limit with an error naming `what` and the rows it saw last, so a wait that never ends says which.
    static func waitFor<T>(_ run: E2ERun, _ what: String, _ match: ([E2EDownload]) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while true {
            let rows = try await run.app.downloads()
            if let value = match(rows) { return value }
            guard Date() < deadline else { throw E2EError("gave up waiting until \(what); rows: \(describe(rows))") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The rows as `name state received "status"`, for a wait's error.
    static func describe(_ rows: [E2EDownload]) -> String {
        rows.isEmpty
            ? "none"
            : rows.map {
                "\($0.fileName) \($0.state) \($0.receivedBytes) \"\($0.status)\""
            }.joined(separator: ", ")
    }

    /// Starts a slow download from `path` in a new background tab beside `page`, and returns the tab and its row
    /// once it runs.
    static func startInTab(
        _ run: E2ERun, _ path: String, fileName: String, besides page: any E2EPage, except earlier: Set<String>
    ) async throws -> (any E2EPage, E2EDownload) {
        let tab = try run.app.openTab(at: E2EFixture.url(path), besides: page, select: false)
        let row = try await waitFor(run, "\(fileName) ran") {
            $0.first {
                !earlier.contains($0.id) && $0.fileName == fileName && $0.state == "inProgress" && $0.receivedBytes > 0
            }
        }
        return (tab, row)
    }

    /// Checks `match` every 20 ms until it returns a value, giving up with an error naming `what` shortly before
    /// the step's limit.
    static func poll<T>(_ what: String, seen: () -> String = { "" }, _ match: () -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while true {
            if let value = match() { return value }
            guard Date() < deadline else { throw E2EError("gave up waiting until \(what) \(seen())") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Cancels the download `row` and clears it, waiting for each.
    static func cancelAndClear(_ run: E2ERun, _ row: E2EDownload) async throws {
        try await run.app.press(.cancelOrClear, of: row)
        let ended = try await waitFor(run, "\(row.fileName) ended") { rows in
            rows.first { $0.id == row.id && $0.state != "inProgress" && $0.state != "paused" }
        }
        try await run.app.press(.cancelOrClear, of: ended)
        _ = try await waitFor(run, "\(row.fileName) was cleared") { rows in
            rows.contains { $0.id == row.id } ? nil : rows
        }
    }
}

/// Closes a tab whose page goes on, once closed, to open a popup, call alert() and start another download on a
/// timer. Its browser stays alive for its first download, but nothing it asks for may reach the screen or keep it
/// alive: no popup browser or window comes of it, the dialog is refused without showing anything, and the download
/// is refused.
struct DownloadsParkedPageTest: E2ETest {
    let name = "downloads.parked-page"
    let checks = ["downloads.parked-popup", "downloads.parked-dialog", "downloads.parked-download"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EKeptTabsApp else { throw E2EError("the app has no kept tabs") }
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("downloads/index.html"))
        }
        try await run.step("load the fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }
        let earlier = Set(try await run.app.downloads().map(\.id))
        do {
            let (tab, row) = try await run.step(
                "start the download in the parked page's tab", timeout: E2ETimeouts.step
            ) {
                try await DownloadRows.startInTab(
                    run, "downloads/parked.html", fileName: "parked.bin", besides: page, except: earlier)
            }
            let browsers = app.openBrowserCount
            let windows = app.shownWindows
            let kinds = ["popup", "dialog", "download"]
            let before = Dictionary(uniqueKeysWithValues: kinds.map { ($0, app.refusedParkedRequests(of: $0)) })
            try await run.step("close the tab", timeout: E2ETimeouts.step) {
                guard try await run.app.closeTab(tab) else { throw E2EError("the parked page's tab did not close") }
            }
            // Each tick of the page calls window.open before alert(), so a refused dialog means it tried a popup too.
            // Chromium itself refuses window.open from a page whose tab closed, so the popup may never reach the
            // engine (which would refuse it); what counts is that no browser or window came of it.
            _ = try await run.step("wait for the closed page's requests", timeout: E2ETimeouts.step * 2) {
                try await DownloadRows.poll(
                    "the closed page asked for a dialog and a download",
                    seen: {
                        "refused "
                            + kinds.map { "\($0)=\(app.refusedParkedRequests(of: $0) - before[$0]!)" }.joined(
                                separator: " ")
                    }
                ) {
                    let counts = kinds.map { app.refusedParkedRequests(of: $0) - before[$0]! }
                    return counts[1] > 0 && counts[2] > 0 ? counts : nil
                }
            }
            // A few more of the page's ticks, so anything shown late is seen too.
            try await Task.sleep(nanoseconds: 500_000_000)
            let refused = kinds.map { app.refusedParkedRequests(of: $0) - before[$0]! }
            let rows = try await run.app.downloads()
            let current = rows.first { $0.id == row.id }
            let again = rows.filter { !earlier.contains($0.id) && $0.fileName.hasPrefix("parked-again") }
            let shown = app.shownWindows
            let kept = current?.state == "inProgress" || current?.state == "paused"
            run.check(
                "downloads.parked-popup",
                passed: kept && app.openBrowserCount == browsers && shown.visible == windows.visible,
                "refused=\(refused[0]) browsers=\(browsers)->\(app.openBrowserCount) windows=\(windows.visible)->\(shown.visible) download=\(current?.state ?? "none")"
            )
            run.check(
                "downloads.parked-dialog", passed: !shown.modal && shown.visible == windows.visible,
                "refused=\(refused[1]) modal=\(shown.modal) windows=\(windows.visible)->\(shown.visible)")
            run.check(
                "downloads.parked-download", passed: again.isEmpty,
                "refused=\(refused[2]) new-rows=\(again.count)")
            try await run.step("cancel the download", timeout: E2ETimeouts.step) {
                try await DownloadRows.cancelAndClear(run, row)
            }
        } catch {
            if error is CancellationError { throw error }
            if let error = error as? E2EError, error.reason == .testEnded { throw error }
            await DownloadRows.cleanUp(run, except: earlier)
            throw error
        }
    }
}

/// Closes a window whose only tab is downloading. The engine keeps the tab's page for its download, so the app does
/// not quit after its last window closes (an e2e run never does, so this checks what that decision reads), and lets
/// go of it once the download is cancelled.
struct DownloadsWindowClosedTest: E2ETest {
    let name = "downloads.window-closed"
    let checks = ["downloads.window-closed"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EKeptTabsApp else { throw E2EError("the app has no kept tabs") }
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("downloads/index.html"))
        }
        try await run.step("load the fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }
        let earlier = Set(try await run.app.downloads().map(\.id))
        do {
            let (tab, row) = try await run.step("start a download in a second tab", timeout: E2ETimeouts.step) {
                try await DownloadRows.startInTab(
                    run, "_slow/320000/window-closed.bin", fileName: "window-closed.bin", besides: page, except: earlier
                )
            }
            let keptBefore = app.keepsClosedTabsForDownloads
            try await run.step("close the window", timeout: E2ETimeouts.step) {
                try await run.app.closeWindow(of: tab)
            }
            let keptAfterClose = app.keepsClosedTabsForDownloads
            let state = try await run.app.downloads().first { $0.id == row.id }?.state ?? "none"
            try await run.step("cancel the download", timeout: E2ETimeouts.step) {
                try await DownloadRows.cancelAndClear(run, row)
            }
            let released = try await run.step("wait for the kept page to go", timeout: E2ETimeouts.step) {
                try await DownloadRows.poll("the engine let go of the closed tab's page") {
                    app.keepsClosedTabsForDownloads ? nil : true
                }
            }
            run.check(
                name, passed: !keptBefore && keptAfterClose && (state == "inProgress" || state == "paused") && released,
                "kept before=\(keptBefore) after-close=\(keptAfterClose) download=\(state) released=\(released)")
        } catch {
            if error is CancellationError { throw error }
            if let error = error as? E2EError, error.reason == .testEnded { throw error }
            await DownloadRows.cleanUp(run, except: earlier)
            throw error
        }
    }
}

/// Clicks a download link twice and a link to a download that never finishes, then drives the downloads window.
struct DownloadsTest: E2ETest {
    let name = "downloads"
    let tags = ["smoke"]
    let checks = ["downloads", "downloads.collision", "downloads.controls", "downloads.list"]

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("downloads/index.html"))
        }
        try await run.step("load the fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
            try await page.emulateFocus()
        }

        let folder = run.downloadsDirectory.standardizedFileURL
        // Each step looks only at rows its own click added, so rows other tests may have left cannot match.
        let first = try await run.step("download a.pdf", timeout: E2ETimeouts.step) {
            let earlier = Set(try await run.app.downloads().map(\.id))
            try await page.click("#pdf")
            return try await waitFor(run) {
                $0.first { !earlier.contains($0.id) && $0.fileName == "a.pdf" && $0.state == "complete" }
            }
        }
        let expected = try Data(contentsOf: try fixtureFile("downloads/a.pdf"))
        let saved = first.path.flatMap { try? Data(contentsOf: $0) }
        let inFolder = first.path?.deletingLastPathComponent().standardizedFileURL == folder
        run.check(
            name,
            passed: saved == expected && inFolder,
            saved == expected && inFolder
                ? "file=\(first.fileName) state=\(first.state)"
                : "file=\(first.fileName) path=\(first.path?.path ?? "none") bytes=\(saved?.count ?? -1)"
        )

        let second = try await run.step("download a.pdf again", timeout: E2ETimeouts.step) {
            let earlier = Set(try await run.app.downloads().map(\.id))
            try await page.click("#pdf")
            return try await waitFor(run) { $0.first { !earlier.contains($0.id) && $0.state == "complete" } }
        }
        let secondSaved = second.path.flatMap { try? Data(contentsOf: $0) }
        let firstKept = first.path.flatMap { try? Data(contentsOf: $0) } == expected
        run.check(
            "downloads.collision",
            passed: second.fileName == "a (1).pdf" && secondSaved == expected && firstKept,
            "file=\(second.fileName) firstUnchanged=\(firstKept)"
        )

        // The endless download must not outlive this test, so a failure in the step below cancels it.
        let earlierSlow = Set(try await run.app.downloads().map(\.id))
        do {
            try await run.step("pause, resume and cancel", timeout: E2ETimeouts.step * 3) {
                let earlier = earlierSlow
                let filesBefore = Set(Self.slowFiles(in: folder))
                try await page.click("#slow")
                var slow = try await waitFor(run) {
                    $0.first {
                        !earlier.contains($0.id) && $0.fileName == "slow.bin" && $0.state == "inProgress"
                            && $0.receivedBytes > 0
                    }
                }
                var states = ["inProgress"]
                try await run.app.press(.pauseOrResume, of: slow)
                slow = try await waitFor(run) { [id = slow.id] in $0.first { $0.id == id && $0.state == "paused" } }
                states.append(slow.state)
                let pausedStatus = slow.status
                let pausedBytes = slow.receivedBytes
                try await run.app.press(.pauseOrResume, of: slow)
                slow = try await waitFor(run) {
                    [id = slow.id] in
                    $0.first { $0.id == id && $0.state == "inProgress" && $0.receivedBytes > pausedBytes }
                }
                states.append(slow.state)
                try await run.app.press(.cancelOrClear, of: slow)
                slow = try await waitFor(run) { [id = slow.id] in $0.first { $0.id == id && $0.state == "cancelled" } }
                states.append(slow.state)
                // Chromium writes slow.bin.crdownload and deletes it asynchronously, so wait briefly for no slow.bin* entry.
                var leftovers = Self.slowFiles(in: folder).filter { !filesBefore.contains($0) }
                for _ in 0..<100 where !leftovers.isEmpty {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    leftovers = Self.slowFiles(in: folder).filter { !filesBefore.contains($0) }
                }
                let leftover = !leftovers.isEmpty
                run.check(
                    "downloads.controls",
                    passed: pausedStatus.hasPrefix("Paused, ") && slow.status == "Cancelled" && !leftover,
                    "states=\(states.joined(separator: ",")) paused=\"\(pausedStatus)\" leftover=\(leftovers.joined(separator: ","))"
                )
            }
        } catch {
            await cancelSlowDownloads(run, except: earlierSlow)
            throw error
        }

        try await run.step("clear a finished download", timeout: E2ETimeouts.step) {
            let before = try await run.app.downloads().map(\.id)
            try await run.app.press(.cancelOrClear, of: first)
            let rows = try await waitFor(run) { rows in rows.contains { $0.id == first.id } ? nil : rows }
            let fileKept = first.path.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            run.check(
                "downloads.list",
                passed: rows.map(\.id) == before.filter { $0 != first.id } && fileKept,
                "rows=\(rows.map(\.fileName).joined(separator: ",")) fileKept=\(fileKept)"
            )
        }
    }

    /// Reads the downloads window until `match` returns a value, checking every 20 ms; the step's timeout bounds it.
    private func waitFor<T>(_ run: E2ERun, _ match: ([E2EDownload]) -> T?) async throws -> T {
        while true {
            if let value = match(try await run.app.downloads()) { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func slowFiles(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("slow.bin") }
    }

    /// Cancels any slow download this test started that is still running.
    private func cancelSlowDownloads(_ run: E2ERun, except earlier: Set<String>) async {
        guard let rows = try? await run.app.downloads() else { return }
        for row in rows
        where !earlier.contains(row.id) && row.fileName == "slow.bin"
            && (row.state == "inProgress" || row.state == "paused")
        {
            try? await run.app.press(.cancelOrClear, of: row)
        }
    }

    private func fixtureFile(_ path: String) throws -> URL {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/\(path)") else {
            throw E2EError("the app bundle has no Fixtures folder")
        }
        return url
    }
}
