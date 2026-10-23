import BowCore
import Foundation
import Testing

@Suite struct HistoryStoreTests {
    let a = URL(string: "https://example.com/a")!
    let b = URL(string: "https://swift.org/blog")!
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bow-history-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func store(persistent: Bool = true, in dir: URL? = nil, profile: ProfileID = "work") throws -> HistoryStore {
        try HistoryStore(profileID: profile, isPersistent: persistent, directory: dir ?? tempDirectory())
    }

    func commit(_ url: URL, _ transition: NavigationTransition = .link) -> TabEvent {
        .didCommit(EngineNavigation(url: url, transition: transition))
    }

    @Test func commitsRecordVisitsAndStateChangesNameThem() throws {
        let store = try store()
        try store.handle(commit(a), at: t0)
        try store.handle(.stateChanged(EngineTabState(tabID: 1, url: a, title: "Page A")), at: t0)
        try store.handle(commit(b, .typed), at: t0 + 10)
        let recent = try store.recent()
        #expect(recent.map(\.url) == [b, a])
        #expect(recent[1].title == "Page A")
        #expect(recent[0].typedCount == 1)
    }

    @Test func otherEventsAndNonCommitsRecordNothing() throws {
        let store = try store()
        try store.handle(.didStartNavigation(EngineNavigation(url: a)), at: t0)
        try store.handle(.didRedirect(EngineNavigation(url: a)), at: t0)
        try store.handle(.didFail(EngineNavigation(url: a), NavigationError(code: -105, description: "x")), at: t0)
        try store.handle(.stateChanged(EngineTabState(tabID: 1, url: a, title: "Unvisited")), at: t0)
        #expect(try store.count() == 0)
    }

    @Test func reloadsAndBackForwardAreNotNewVisits() throws {
        let store = try store()
        try store.handle(commit(a), at: t0)
        try store.handle(commit(a, .reload), at: t0 + 1)
        try store.handle(commit(a, .backForward), at: t0 + 2)
        #expect(try store.entry(for: a)?.visitCount == 1)
    }

    @Test func repeatVisitsFoldIntoOneEntryAndKeepEachVisit() throws {
        let store = try store()
        try store.recordVisit(url: a, title: "First", transition: .typed, at: t0)
        try store.recordVisit(url: a, title: "", transition: .link, at: t0 + 60)
        let entry = try #require(try store.entry(for: a))
        #expect(entry.visitCount == 2)
        #expect(entry.typedCount == 1)
        #expect(entry.title == "First")
        #expect(entry.lastVisit == t0 + 60)
        #expect(try store.visits(for: a).map(\.transition) == [.link, .typed])
    }

    @Test func fragmentsDoNotMakeNewPages() throws {
        let store = try store()
        try store.recordVisit(url: URL(string: "https://example.com/a#one")!, at: t0)
        try store.recordVisit(url: URL(string: "https://example.com/a#two")!, at: t0 + 1)
        #expect(try store.count() == 1)
    }

    @Test func internalAndOpaqueSchemesAreNotRecorded() throws {
        let store = try store()
        for text in ["about:blank", "data:text/html,hi", "chrome://settings", "javascript:alert(1)", "bow://x"] {
            try store.recordVisit(url: URL(string: text)!, at: t0)
        }
        #expect(try store.count() == 0)
        try store.recordVisit(url: URL(string: "file:///tmp/x.html")!, at: t0)
        #expect(try store.count() == 1)
    }

    @Test func searchMatchesEveryWordInURLOrTitleIgnoringCase() throws {
        let store = try store()
        try store.recordVisit(url: a, title: "Quarterly Report", at: t0)
        try store.recordVisit(url: b, title: "Swift Blog", at: t0 + 1)
        #expect(try store.search("quarterly").map(\.url) == [a])
        #expect(try store.search("EXAMPLE report").map(\.url) == [a])
        #expect(try store.search("swift.org blog").map(\.url) == [b])
        #expect(try store.search("report blog").isEmpty)
        #expect(try store.search("   ").isEmpty)
    }

    @Test func searchTreatsWildcardsAsPlainText() throws {
        let store = try store()
        try store.recordVisit(url: a, title: "100% done", at: t0)
        try store.recordVisit(url: b, title: "plain", at: t0)
        #expect(try store.search("%").map(\.url) == [a])
        #expect(try store.search("_").isEmpty)
    }

    @Test func searchRanksFrequentThenRecent() throws {
        let store = try store()
        let c = URL(string: "https://example.com/c")!
        try store.recordVisit(url: a, at: t0)
        try store.recordVisit(url: b, at: t0 + 5)
        try store.recordVisit(url: c, at: t0 + 6)
        try store.recordVisit(url: a, at: t0 + 7)
        #expect(try store.search("://", limit: 10).map(\.url) == [a, c, b])
        #expect(try store.search("://", limit: 1).map(\.url) == [a])
    }

    @Test func recentHonorsLimit() throws {
        let store = try store()
        try store.recordVisit(url: a, at: t0)
        try store.recordVisit(url: b, at: t0 + 1)
        #expect(try store.recent(limit: 1).map(\.url) == [b])
        #expect(try store.recent(limit: 0).isEmpty)
    }

    @Test func deleteOnePageRemovesItsVisits() throws {
        let store = try store()
        try store.recordVisit(url: a, at: t0)
        try store.recordVisit(url: b, at: t0 + 1)
        try store.delete(url: a)
        #expect(try store.recent().map(\.url) == [b])
        #expect(try store.visits(for: a).isEmpty)
    }

    @Test func deleteRangeKeepsOtherVisitsAndFixesCounts() throws {
        let store = try store()
        try store.recordVisit(url: a, transition: .typed, at: t0)
        try store.recordVisit(url: a, transition: .link, at: t0 + 100)
        try store.recordVisit(url: b, at: t0 + 100)
        try store.delete(visitsIn: (t0 + 50)...(t0 + 150))
        #expect(try store.recent().map(\.url) == [a])
        let entry = try #require(try store.entry(for: a))
        #expect(entry.visitCount == 1)
        #expect(entry.typedCount == 1)
        #expect(entry.lastVisit == t0)
    }

    @Test func deleteAllEmptiesTheStore() throws {
        let store = try store()
        try store.recordVisit(url: a, at: t0)
        try store.deleteAll()
        #expect(try store.count() == 0)
        #expect(try store.visits(for: a).isEmpty)
    }

    @Test func persistentHistorySurvivesReopeningAndIsPerProfile() throws {
        let dir = try tempDirectory()
        let work = try store(in: dir, profile: "work")
        try work.recordVisit(url: a, title: "A", at: t0)
        let file = try #require(work.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path))

        let reopened = try store(in: dir, profile: "work")
        #expect(try reopened.entry(for: a)?.title == "A")
        let other = try store(in: dir, profile: "personal")
        #expect(try other.count() == 0)
        #expect(other.fileURL != work.fileURL)
    }

    @Test func profileNamesCannotEscapeTheDirectory() throws {
        let dir = try tempDirectory()
        let store = try store(in: dir, profile: "../../evil")
        let file = try #require(store.fileURL)
        #expect(
            file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func ephemeralProfileWritesNothingToDisk() throws {
        let dir = try tempDirectory()
        let store = try store(persistent: false, in: dir, profile: "private")
        try store.recordVisit(url: a, title: "A", at: t0)
        try store.handle(commit(b), at: t0 + 1)
        #expect(store.fileURL == nil)
        #expect(try store.count() == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        let again = try self.store(persistent: false, in: dir, profile: "private")
        #expect(try again.count() == 0)
    }

    @Test func searchIgnoresCaseOutsideASCIIToo() throws {
        let store = try store()
        try store.recordVisit(url: a, title: "Übersicht Москва", at: t0)
        #expect(try store.search("übersicht").count == 1)
        #expect(try store.search("МОСКВА").count == 1)
    }

    @Test func titleThatArrivesBeforeTheCommitIsKept() throws {
        let store = try store()
        try store.handle(.stateChanged(EngineTabState(tabID: 1, url: a, title: "Early")), at: t0)
        try store.handle(commit(a), at: t0 + 1)
        #expect(try store.entry(for: a)?.title == "Early")
        #expect(try store.search("early").count == 1)
    }

    @Test func schemeAndHostCaseAndBareHostSlashAreOnePage() throws {
        let store = try store()
        try store.recordVisit(url: URL(string: "https://Example.com")!, at: t0)
        try store.recordVisit(url: URL(string: "HTTPS://example.com/")!, at: t0 + 1)
        #expect(try store.count() == 1)
        #expect(try store.entry(for: URL(string: "https://example.com")!)?.visitCount == 2)
    }

    @Test func profilesDifferingOnlyByCaseGetSeparateFiles() throws {
        let dir = try tempDirectory()
        let upper = try store(in: dir, profile: "Work")
        let lower = try store(in: dir, profile: "work")
        try upper.recordVisit(url: a, at: t0)
        #expect(try lower.count() == 0)
    }

    @Test func titleWithEmbeddedNULIsStoredWhole() throws {
        let store = try store()
        try store.recordVisit(url: a, title: "ab\u{0}cd", at: t0)
        #expect(try store.entry(for: a)?.title == "ab\u{0}cd")
    }

    @Test func twoStoresOnOneFileBothWrite() throws {
        let dir = try tempDirectory()
        let first = try store(in: dir)
        let second = try store(in: dir)
        try first.recordVisit(url: a, at: t0)
        try second.recordVisit(url: b, at: t0 + 1)
        #expect(try first.count() == 2)
    }

    @Test func concurrentRecordingIsSafe() async throws {
        let store = try store()
        let url = a
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { try? store.recordVisit(url: url, at: Date(timeIntervalSince1970: Double(i))) }
            }
        }
        #expect(try store.entry(for: a)?.visitCount == 50)
    }
}
