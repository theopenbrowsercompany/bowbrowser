import Foundation

/// Tests of downloads: saving into the downloads folder, numbering taken names, and pausing, resuming, cancelling
/// and clearing from the downloads window. Fixtures in E2E/Fixtures/downloads/.
@MainActor
enum DownloadsTests {
    static let all: [any E2ETest] = [DownloadsTest(), DownloadsTabClosedTest()]
}

/// Opens a slow download of known size in a second tab and closes that tab mid download. Chromium stops reporting a
/// download once its tab closes (and CEF cancels it), so the row must update from disk to Cancelled, clear, and free
/// its name.
struct DownloadsTabClosedTest: E2ETest {
    let name = "downloads.tab-closed"
    let checks = ["downloads.tab-closed"]
    /// About three seconds at the fixture's pace (1 KB every 20 ms).
    static let size: Int64 = 160_000

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("downloads/index.html"))
        }
        try await run.step("load the fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }

        let earlier = Set(try await run.app.downloads().map(\.id))
        let atClose = try await run.step("start the download in a second tab and close it", timeout: E2ETimeouts.step) {
            let tab = try run.app.openTab(
                at: E2EFixture.url("_slow/\(Self.size)/tab-closed.bin"), besides: page, select: false)
            let row = try await waitFor(run) {
                $0.first {
                    !earlier.contains($0.id) && $0.fileName == "tab-closed.bin" && $0.state == "inProgress"
                        && $0.receivedBytes > 0
                }
            }
            guard row.receivedBytes < Self.size / 2 else {
                throw E2EError("the download got \(row.receivedBytes) bytes before the tab could close")
            }
            guard try await run.app.closeTab(tab) else { throw E2EError("the download's tab did not close") }
            return row
        }

        do {
            try await run.step("follow the download and clear it", timeout: E2ETimeouts.step * 2) {
                // CEF aborts every request of a browser it destroys, which cancels the download; the row must say so.
                let done = try await waitFor(run) { rows -> E2EDownload? in
                    rows.first { $0.id == atClose.id && $0.state != "inProgress" }
                }
                let fileLeft = done.path.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                let updated = done.state != atClose.state || done.receivedBytes != atClose.receivedBytes

                // The cancelled row clears, and its name is free for the next download of the file.
                try await run.app.press(.cancelOrClear, of: done)
                _ = try await waitFor(run) { rows in rows.contains { $0.id == done.id } ? nil : rows }
                let again = try run.app.openTab(
                    at: E2EFixture.url("_slow/\(Self.size)/tab-closed.bin"), besides: page, select: false)
                let next = try await waitFor(run) {
                    $0.first {
                        !earlier.contains($0.id) && $0.id != done.id && $0.state == "inProgress" && $0.path != nil
                    }
                }
                try await run.app.press(.cancelOrClear, of: next)
                _ = try await waitFor(run) { [id = next.id] in $0.first { $0.id == id && $0.state == "cancelled" } }
                _ = try await run.app.closeTab(again)

                let passed =
                    done.state == "cancelled" && done.status == "Cancelled" && updated && !fileLeft
                    && next.fileName == "tab-closed.bin"
                run.check(
                    name,
                    passed: passed,
                    "state=\(done.state) row=\(updated ? "updated" : "frozen")"
                        + (passed ? "" : " status=\"\(done.status)\" fileLeft=\(fileLeft) next=\(next.fileName)")
                )
            }
        } catch {
            await cancelRunning(run, except: earlier)
            throw error
        }
    }

    /// Cancels any download this test started that is still running.
    private func cancelRunning(_ run: E2ERun, except earlier: Set<String>) async {
        guard let rows = try? await run.app.downloads() else { return }
        for row in rows where !earlier.contains(row.id) && (row.state == "inProgress" || row.state == "paused") {
            try? await run.app.press(.cancelOrClear, of: row)
        }
    }

    /// Reads the downloads window until `match` returns a value, checking every 20 ms; the step's timeout bounds it.
    private func waitFor<T>(_ run: E2ERun, _ match: ([E2EDownload]) -> T?) async throws -> T {
        while true {
            if let value = match(try await run.app.downloads()) { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Clicks a download link twice and a link to a download that never finishes, then drives the downloads window.
struct DownloadsTest: E2ETest {
    let name = "downloads"
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
