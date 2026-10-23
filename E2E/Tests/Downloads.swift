import Foundation

/// Tests of downloads: saving into the downloads folder, numbering taken names, and pausing, resuming, cancelling
/// and clearing from the downloads window. Fixtures in E2E/Fixtures/downloads/.
@MainActor
enum DownloadsTests {
    static let all: [any E2ETest] = [DownloadsTest()]
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
        // Earlier tests in a full run may have left downloads of their own in the list (a page answering 204 or
        // failing to load is a download too), so each step looks only at rows its own click added.
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
        run.check(
            "downloads.collision",
            passed: second.fileName == "a (1).pdf"
                && second.path.map { FileManager.default.fileExists(atPath: $0.path) }
                    == true,
            "file=\(second.fileName)"
        )

        try await run.step("pause, resume and cancel", timeout: E2ETimeouts.step * 3) {
            let earlier = Set(try await run.app.downloads().map(\.id))
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
                [id = slow.id] in $0.first { $0.id == id && $0.state == "inProgress" && $0.receivedBytes > pausedBytes }
            }
            states.append(slow.state)
            try await run.app.press(.cancelOrClear, of: slow)
            slow = try await waitFor(run) { [id = slow.id] in $0.first { $0.id == id && $0.state == "cancelled" } }
            states.append(slow.state)
            let leftover = slow.path.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            run.check(
                "downloads.controls",
                passed: pausedStatus.hasPrefix("Paused, ") && slow.status == "Cancelled" && !leftover,
                "states=\(states.joined(separator: ",")) paused=\"\(pausedStatus)\" leftover=\(leftover)"
            )
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

    private func fixtureFile(_ path: String) throws -> URL {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/\(path)") else {
            throw E2EError("the app bundle has no Fixtures folder")
        }
        return url
    }
}
