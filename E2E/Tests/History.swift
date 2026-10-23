import Foundation

/// Tests of the browsing history the app records from tabs' committed navigations. Uses the store fixture, whose
/// pages are titled after their `name` parameter. Specified in spec/history.md.
@MainActor
enum HistoryTests {
    static let all: [any E2ETest] = [
        HistoryRecordingTest()
    ]
}

/// Navigates a tab in an in-memory profile to A then B and reads the profile's history; then does the same to C then
/// D in a persistent profile, whose history file a store of its own reads back.
struct HistoryRecordingTest: E2ETest {
    let name = "history.recording"
    let tags = ["smoke"]
    let checks = ["history", "history.title", "history.ephemeral", "history.persistent", "history.profiles"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EHistoryApp else { throw E2EError("the app has no history to read") }

        // In memory: the test's own profile.
        let memory = try await Self.visit(run, name: "memory", first: "A", second: "B", profile: nil)
        let entries = try await Self.waitForTitles(app, memory, count: 2)
        run.check(
            "history", passed: Self.names(entries) == ["A", "B"],
            "visits=[\(Self.names(entries).joined(separator: ","))]")
        let titles = entries.map(\.title)
        run.check("history.title", passed: titles == ["A", "B"], "titles=[\(titles.joined(separator: ","))]")

        // An in-memory profile leaves no history file and no history folder, though it records.
        let (file, hasFolder) = try await run.step("look for history files", timeout: E2ETimeouts.step) {
            (try app.historyFile(of: memory), try app.hasHistoryFolder(of: memory))
        }
        run.check(
            "history.ephemeral", passed: file == nil && !hasFolder && entries.count == 2,
            "file=\(file?.path ?? "none") folder=\(hasFolder ? "exists" : "none")")

        // On disk: a persistent profile.
        let disk = try await Self.visit(
            run, name: "disk", first: "C", second: "D", profile: E2EProfile(id: "e2e-history-disk", isPersistent: true))
        let diskEntries = try await Self.waitForTitles(app, disk, count: 2)
        let read = try await run.step("read the history file", timeout: E2ETimeouts.step) { () -> [E2EHistoryEntry]? in
            guard let file = try app.historyFile(of: disk) else { return nil }
            return try app.historyEntries(inFile: file)
        }
        let readNames = read.map(Self.names) ?? []
        run.check(
            "history.persistent",
            passed: Self.names(diskEntries) == ["C", "D"] && read.map({ $0 == diskEntries }) == true,
            "memory=[\(Self.names(diskEntries).joined(separator: ","))] file=[\(readNames.joined(separator: ","))]")

        // Each profile keeps its own.
        let (again, diskAgain) = try await run.step("read both profiles again", timeout: E2ETimeouts.step) {
            (try app.historyEntries(of: memory), try app.historyEntries(of: disk))
        }
        run.check(
            "history.profiles", passed: Self.names(again) == ["A", "B"] && Self.names(diskAgain) == ["C", "D"],
            "memory=[\(Self.names(again).joined(separator: ","))] disk=[\(Self.names(diskEntries).joined(separator: ","))]"
        )
    }

    /// Opens a window on page `first`, then navigates its tab to `second`.
    private static func visit(
        _ run: E2ERun, name: String, first: String, second: String, profile: E2EProfile?
    ) async throws -> any E2EPage {
        try await run.step("visit \(first) then \(second) (\(name))", timeout: E2ETimeouts.firstLoad) {
            let page: any E2EPage
            if let profile {
                page = try await run.app.openWindow(at: StoreTests.url(first), newProfile: profile)
            } else {
                page = try await run.app.openWindow(at: StoreTests.url(first))
            }
            _ = try await page.waitForLoad(after: 0)
            let loads = page.finishedLoads
            try page.load(StoreTests.url(second))
            _ = try await page.waitForLoad(after: loads)
            return page
        }
    }

    /// The history of `page`'s profile once it holds `count` pages, all titled (a title can arrive after the load).
    private static func waitForTitles(_ app: any E2EHistoryApp, _ page: any E2EPage, count: Int) async throws
        -> [E2EHistoryEntry]
    {
        let deadline = Date().addingTimeInterval(E2EWaits.budget(limit: 5))
        var entries = try app.historyEntries(of: page)
        while Date() < deadline, entries.count < count || entries.contains(where: { $0.title.isEmpty }) {
            try await Task.sleep(nanoseconds: 50_000_000)
            entries = try app.historyEntries(of: page)
        }
        return entries
    }

    /// The `name` parameter of each page.
    private static func names(_ entries: [E2EHistoryEntry]) -> [String] {
        entries.map { entry in
            URLComponents(url: entry.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "name" }?.value ?? entry.url.absoluteString
        }
    }
}
