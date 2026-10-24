import Foundation
import SQLite3
import Testing

@testable import BowCore

/// Importing history and bookmarks from a Chromium User Data folder: the files read, the History copy, the profile
/// mapping, the visits brought into a history store and taken out again, and the bookmarks folder with its undo.
/// Every folder here is built by hand with example.com URLs; no real browser profile is read.
@Suite struct ArcChromiumHistoryImportTests {
    typealias Fixture = ArcChromiumImportTests

    /// A User Data folder with `Local State` listing Default and Profile 7, each with History; Default with Bookmarks.
    /// Decoy Cookies and Login Data files sit beside them and must never be read.
    static func userData(in folder: URL) throws -> URL {
        let root = folder.appendingPathComponent("User Data", isDirectory: true)
        let fm = FileManager.default
        for profile in ["Default", "Profile 7"] {
            let dir = root.appendingPathComponent(profile, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Fixture.writeHistory(to: dir)
            for decoy in ["Cookies", "Login Data", "Web Data"] {
                try Data("decoy".utf8).write(to: dir.appendingPathComponent(decoy))
            }
        }
        try Data(Fixture.bookmarks.utf8).write(to: root.appendingPathComponent("Default/Bookmarks"))
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 7":{"name":"Work"}}}}"#.utf8)
            .write(to: root.appendingPathComponent("Local State"))
        return root
    }

    // MARK: Time

    @Test func chromiumTimeIsMicrosecondsSince1601() {
        #expect(ChromiumTime.date(microseconds: 11_644_473_600_000_000) == Date(timeIntervalSince1970: 0))
        #expect(ChromiumTime.date(microseconds: Fixture.t0) == Fixture.t0Date)
        #expect(ChromiumTime.date(microseconds: Fixture.t0 + 1_500_000) == Fixture.t0Date.addingTimeInterval(1.5))
        #expect(ChromiumTime.date(microseconds: 0) == nil)
        #expect(ChromiumTime.date(microseconds: -5) == nil)
    }

    // MARK: Files read

    @Test func readingTouchesOnlyLocalStateBookmarksAndHistoryCopies() throws {
        try withTemporaryFolder { folder in
            let root = try Self.userData(in: folder)
            let temp = folder.appendingPathComponent("temp", isDirectory: true)
            let log = ChromiumFileLog()
            let data = try ChromiumUserData.read(root, temporaryFolder: temp, log: log)
            #expect(data.map(\.profile.directory) == ["Default", "Profile 7"])
            #expect(data[0].visits.count == 3)
            #expect(data[0].bookmarks?.bookmarkCount == 4)
            #expect(data[1].bookmarks == nil)
            #expect(data[1].problems == [.missingFile("Bookmarks")])
            let names = log.originals.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
            #expect(names == ["Local State", "Default/History", "Default/Bookmarks", "Profile 7/History"])
            // SQLite only ever opened copies inside the temporary folder, and every copy is gone.
            let opened = log.events.compactMap { event -> URL? in
                if case .opened(let url) = event { return url }
                return nil
            }
            #expect(!opened.isEmpty)
            #expect(opened.allSatisfy { $0.path.hasPrefix(temp.path + "/") })
            let left = try FileManager.default.contentsOfDirectory(atPath: temp.path)
            #expect(left.isEmpty)
        }
    }

    @Test func walAndJournalAreCopiedButShmIsNot() throws {
        try withTemporaryFolder { folder in
            try Fixture.writeHistory(to: folder)
            for side in ["History-wal", "History-shm"] {
                try Data().write(to: folder.appendingPathComponent(side))
            }
            let log = ChromiumFileLog()
            _ = try ChromiumHistory.loadReport(profileFolder: folder, log: log)
            #expect(log.originals.map(\.lastPathComponent) == ["History", "History-wal"])
        }
    }

    @Test func notAUserDataFolderIsRefused() throws {
        try withTemporaryFolder { folder in
            #expect(throws: ChromiumUserData.Refusal.notUserData(.missingFile("Local State"))) {
                try ChromiumUserData.read(folder)
            }
            try Data("[1]".utf8).write(to: folder.appendingPathComponent("Local State"))
            #expect(throws: ChromiumUserData.Refusal.self) { try ChromiumUserData.read(folder) }
            try Data(#"{"profile":{"info_cache":{}}}"#.utf8).write(to: folder.appendingPathComponent("Local State"))
            #expect(throws: ChromiumUserData.Refusal.noProfiles) { try ChromiumUserData.read(folder) }
        }
    }

    @Test func aCancelledReadStopsBeforeTheNextProfile() throws {
        try withTemporaryFolder { folder in
            let root = try Self.userData(in: folder)
            var asked = 0
            let data = try ChromiumUserData.read(root) {
                asked += 1
                return asked > 1
            }
            #expect(data.map(\.profile.directory) == ["Default"])
        }
    }

    @Test func corruptHistoryIsAProblemAndItsCopyIsRemoved() throws {
        try withTemporaryFolder { folder in
            let root = try Self.userData(in: folder)
            try Data(repeating: 0x41, count: 4096).write(to: root.appendingPathComponent("Profile 7/History"))
            let temp = folder.appendingPathComponent("temp", isDirectory: true)
            let data = try ChromiumUserData.read(root, temporaryFolder: temp)
            #expect(data[0].visits.count == 3)
            #expect(data[1].visits.isEmpty)
            #expect(data[1].problems.contains { if case .database = $0 { true } else { false } })
            #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
        }
    }

    @Test func unreadableHistoryIsAProblemAndItsCopyIsRemoved() throws {
        try withTemporaryFolder { folder in
            let root = try Self.userData(in: folder)
            let history = root.appendingPathComponent("Default/History")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: history.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: history.path) }
            let temp = folder.appendingPathComponent("temp", isDirectory: true)
            let data = try ChromiumUserData.read(root, temporaryFolder: temp)
            #expect(data[0].visits.isEmpty)
            #expect(data[0].bookmarks?.bookmarkCount == 4)
            #expect(data[0].problems.contains { if case .database = $0 { true } else { false } })
            #expect(try FileManager.default.contentsOfDirectory(atPath: temp.path).isEmpty)
        }
    }

    @Test func aHotJournalIsRolledBackInTheCopyOnly() throws {
        try withTemporaryFolder { folder in
            try Fixture.writeHistory(to: folder)
            let main = folder.appendingPathComponent("History")
            let before = try Data(contentsOf: main)
            // A journal that is not a valid rollback journal for this file is ignored; the read still works and the
            // original and its journal stay byte for byte as they were.
            let journal = folder.appendingPathComponent("History-journal")
            try Data(repeating: 0, count: 512).write(to: journal)
            let visits = try ChromiumHistory.load(profileFolder: folder)
            #expect(visits.count == 3)
            #expect(try Data(contentsOf: main) == before)
            #expect(try Data(contentsOf: journal) == Data(repeating: 0, count: 512))
        }
    }

    // MARK: Profile mapping

    @Test func profilesMapToTheBowProfileTheSidebarImportMade() {
        let profiles = [
            ChromiumProfile(directory: "Default", displayName: "Personal"),
            ChromiumProfile(directory: "Profile 1", displayName: "Work"),
            ChromiumProfile(directory: "Profile 9", displayName: "Old"),
        ]
        let work = ArcImportProfileTarget.profileID(forArcProfile: "Profile 1")
        let fallback = SidebarProfileID("on-screen")
        let targets = ChromiumImportMapping.targets(for: profiles, isKnown: { $0 == work }, fallback: fallback)
        #expect(targets.map(\.bowProfile) == [.default, work, fallback])
        #expect(targets.map(\.matched) == [true, true, false])
        // The default profile always matches, even when the registry does not list it.
        let none = ChromiumImportMapping.targets(for: [profiles[0]], isKnown: { _ in false }, fallback: fallback)
        #expect(none.first?.bowProfile == .default)
    }

    @Test func visitsMapTransitionsAndDropReloads() {
        let date = Fixture.t0Date
        let visits = [
            ChromiumVisit(url: "https://example.com/a", title: "A", date: date, transition: 1),
            ChromiumVisit(url: "https://example.com/b", title: "", date: date, transition: 0),
            ChromiumVisit(url: "https://example.com/c", title: "", date: date, transition: 7),
            ChromiumVisit(url: "https://example.com/d", title: "", date: date, transition: 8),
            ChromiumVisit(url: "https://example.com/e", title: "", date: date, transition: 5),
            ChromiumVisit(url: "https://exa mple.com/bad", title: "", date: date, transition: 0),
        ]
        let mapped = ChromiumImportMapping.historyVisits(from: visits)
        #expect(mapped.map(\.url.lastPathComponent) == ["a", "b", "c", "e"])
        #expect(mapped.map(\.transition) == [.typed, .link, .formSubmit, .other])
        #expect(mapped[0].title == "A")
        #expect(mapped[0].time == date)
    }

    @Test func bookmarksGoToTheSpaceOnScreenOrTheFirstSpaceOfTheProfile() throws {
        let work = SidebarProfileID("work")
        var graph = SidebarGraph.fresh()
        let starter = try #require(graph.activeSpace)
        let workSpace = SidebarSpaceID.make()
        graph = try graph.applying([.insertSpace(workSpace, title: "Work", profileID: work)])
        #expect(ChromiumImportMapping.bookmarksSpace(for: .default, in: graph) == starter.id)
        #expect(ChromiumImportMapping.bookmarksSpace(for: work, in: graph) == workSpace)
        #expect(ChromiumImportMapping.bookmarksSpace(for: SidebarProfileID("other"), in: graph) == starter.id)
        graph = try graph.applying([.setActiveSpace(workSpace)])
        #expect(ChromiumImportMapping.bookmarksSpace(for: work, in: graph) == workSpace)
        #expect(ChromiumImportMapping.bookmarksSpace(for: .default, in: graph) == starter.id)
    }

    @Test func previewSaysWhereEachProfileGoes() {
        let personal = ChromiumProfile(directory: "Default", displayName: "Personal")
        let old = ChromiumProfile(directory: "Profile 9", displayName: "Old")
        let visit = ChromiumVisit(url: "https://example.com/a", title: "A", date: Fixture.t0Date, transition: 0)
        let bookmarks = try? ChromiumBookmarks.parse(data: Data(Fixture.bookmarks.utf8))
        let preview = ChromiumImportPreview(
            data: [
                ChromiumProfileData(profile: personal, visits: [visit, visit], bookmarks: bookmarks, problems: []),
                ChromiumProfileData(
                    profile: old, visits: [visit], bookmarks: nil, problems: [.missingFile("Bookmarks")]),
            ], isKnown: { _ in false }, fallback: SidebarProfileID("t"))
        #expect(preview.visitCount == 3)
        #expect(preview.bookmarkCount == 4)
        let lines = preview.lines(bookmarks: .pinnedFolder, profileName: { _ in "Default" }, fallbackSpaceTitle: "Home")
        #expect(
            lines == [
                "Personal: 2 visits and 4 bookmarks, into the Default profile.",
                "Old: 1 visit. No Bow profile matches this Arc profile, so it goes to the profile of the Space on "
                    + "screen, Home.",
                "Old: Bookmarks was not found in the profile folder.",
            ])
        let skipped = preview.lines(bookmarks: .skip, profileName: { _ in "Default" }, fallbackSpaceTitle: "Home")
        #expect(skipped[0] == "Personal: 2 visits, into the Default profile.")
        #expect(!preview.isEmpty(bookmarks: .skip))
        #expect(preview.bookmarkFolders(.skip, in: .fresh()).isEmpty)
        let folders = preview.bookmarkFolders(.pinnedFolder, in: .fresh())
        #expect(folders.map(\.title) == ["Arc Bookmarks"])
    }

    @Test func folderTitleNamesTheProfileWhenSeveralBringBookmarks() {
        let work = ChromiumProfile(directory: "Profile 1", displayName: "Work")
        #expect(ChromiumImportMapping.bookmarksFolderTitle(for: work, profilesWithBookmarks: 1) == "Arc Bookmarks")
        #expect(
            ChromiumImportMapping.bookmarksFolderTitle(for: work, profilesWithBookmarks: 2) == "Arc Bookmarks (Work)")
    }

    // MARK: History store

    static func store() throws -> HistoryStore {
        try HistoryStore(
            profileID: "import-test", isPersistent: false, directory: FileManager.default.temporaryDirectory)
    }

    static func visit(_ path: String, _ seconds: Double, title: String = "", _ transition: NavigationTransition = .link)
        -> HistoryImportVisit
    {
        HistoryImportVisit(
            url: URL(string: "https://example.com/\(path)")!, title: title,
            time: Fixture.t0Date.addingTimeInterval(seconds), transition: transition)
    }

    @Test func importAddsVisitsWithCountsAndTitles() throws {
        let store = try Self.store()
        let record = try store.importVisits([
            Self.visit("a", 0, title: "Page A", .typed), Self.visit("a", 60), Self.visit("b", 120),
            HistoryImportVisit(url: URL(string: "chrome://settings")!, time: Fixture.t0Date),
        ])
        #expect(record.addedCount == 3)
        #expect(record.skippedCount == 1)
        let a = try #require(try store.entry(for: URL(string: "https://example.com/a")!))
        #expect(a.visitCount == 2)
        #expect(a.typedCount == 1)
        #expect(a.title == "Page A")
        #expect(a.lastVisit == Fixture.t0Date.addingTimeInterval(60))
        #expect(try store.search("page a").map(\.url.lastPathComponent) == ["a"])
    }

    @Test func importingTheSameVisitsAgainAddsNothing() throws {
        let store = try Self.store()
        let visits = [Self.visit("a", 0), Self.visit("a", 60), Self.visit("b", 120)]
        _ = try store.importVisits(visits)
        let again = try store.importVisits(visits)
        #expect(again.addedCount == 0)
        #expect(again.skippedCount == 3)
        #expect(try store.visitCount() == 3)
    }

    @Test func importNeverReplacesATitleSeenLive() throws {
        let store = try Self.store()
        let url = URL(string: "https://example.com/a")!
        try store.recordVisit(url: url, title: "Live title", at: Date())
        _ = try store.importVisits([Self.visit("a", 0, title: "Old title")])
        #expect(try store.entry(for: url)?.title == "Live title")
        #expect(try store.entry(for: url)?.visitCount == 2)
    }

    @Test func removingAnImportTakesOutOnlyItsVisits() throws {
        let store = try Self.store()
        let a = URL(string: "https://example.com/a")!
        try store.recordVisit(url: a, title: "A", at: Fixture.t0Date.addingTimeInterval(-60))
        let record = try store.importVisits([Self.visit("a", 0, .typed), Self.visit("b", 60)])
        // A visit the person makes after the import, to a page the import brought.
        let later = Date()
        try store.recordVisit(url: URL(string: "https://example.com/b")!, at: later)
        #expect(try store.removeImported(record) == 2)
        let entryA = try #require(try store.entry(for: a))
        #expect(entryA.visitCount == 1)
        #expect(entryA.typedCount == 0)
        #expect(entryA.lastVisit == Fixture.t0Date.addingTimeInterval(-60))
        let entryB = try #require(try store.entry(for: URL(string: "https://example.com/b")!))
        #expect(entryB.visitCount == 1)
        // Removing again finds nothing left to remove.
        #expect(try store.removeImported(record) == 0)
    }

    @Test func removingAnImportDropsPagesOnlyTheImportBrought() throws {
        let store = try Self.store()
        let record = try store.importVisits([Self.visit("a", 0), Self.visit("b", 60)])
        try store.removeImported(record)
        #expect(try store.count() == 0)
        #expect(try store.visitCount() == 0)
    }

    @Test func aVisitThatReusedARowIDIsNotRemoved() throws {
        let store = try Self.store()
        let record = try store.importVisits([Self.visit("a", 0), Self.visit("b", 60)])
        try store.deleteAll()
        // New visits may get the deleted rows' IDs back; their times differ, so they are not the import's.
        try store.recordVisit(url: URL(string: "https://example.com/c")!)
        try store.recordVisit(url: URL(string: "https://example.com/d")!)
        #expect(try store.removeImported(record) == 0)
        #expect(try store.visitCount() == 2)
    }

    @Test func importInChunksDedupesAcrossChunksAndUndoesAsOne() throws {
        let store = try Self.store()
        // Chunks of 2: the repeat of "a" at 0 lands in the second chunk, the repeat of "b" in the third.
        let visits = [
            Self.visit("a", 0), Self.visit("b", 60), Self.visit("a", 0), Self.visit("c", 120), Self.visit("b", 60),
        ]
        var progress: [Int] = []
        let record = try store.importVisits(visits, chunkSize: 2) { progress.append($0) }
        #expect(progress == [2, 4, 5])
        #expect(record.addedCount == 3)
        #expect(record.skippedCount == 2)
        #expect(try store.visitCount() == 3)
        #expect(try store.removeImported(record) == 3)
        #expect(try store.count() == 0)
    }

    @Test func importLetsTheLockGoBetweenChunks() throws {
        let store = try Self.store()
        let visits = (0..<6).map { Self.visit("p\($0)", Double($0)) }
        let live = URL(string: "https://example.com/live")!
        let pageLoad = LivePageLoad()
        var lockWasFreeBetweenChunks = false
        let record = try store.importVisits(visits, chunkSize: 3) { done in
            guard done == 3 else { return }
            // A page load on its own thread while the import waits between chunks. The import cannot go on until the
            // page load has finished, so the page load either got the lock (it is free) or waits for the import to
            // let it go (it is held). Its own thread starts at once, unlike a shared queue that a busy test process
            // can keep from starting it. The bounded wait only keeps a held lock from hanging the test: it is far
            // above how long one insert takes, even on a loaded machine.
            pageLoad.start { try store.recordVisit(url: live, title: "Live") }
            lockWasFreeBetweenChunks = pageLoad.waitUntilFinished(seconds: 60)
        }
        #expect(lockWasFreeBetweenChunks, "the page load waited 60 s for the lock: the import held it between chunks")
        // A held lock lets the page load through once the import is over; wait for it so the checks below see it.
        let pageLoadFinished = lockWasFreeBetweenChunks || pageLoad.waitUntilFinished(seconds: 60)
        if pageLoadFinished {
            #expect(pageLoad.error == nil, "recording the page load failed: \(String(describing: pageLoad.error))")
        }
        #expect(record.addedCount == 6)
        // The live visit is not the import's: undo leaves it.
        #expect(try store.removeImported(record) == 6)
        #expect(try store.entry(for: live)?.visitCount == 1)
    }

    /// Runs one store call on a thread of its own and lets the test wait for it to finish.
    final class LivePageLoad: @unchecked Sendable {
        private let finished = DispatchSemaphore(value: 0)
        /// The error the call threw; read it only after `waitUntilFinished` returned true.
        private(set) var error: Error?

        func start(_ body: @escaping @Sendable () throws -> Void) {
            let thread = Thread { [self] in
                do { try body() } catch { self.error = error }
                finished.signal()
            }
            thread.start()
        }

        /// Whether the call finished within `seconds`.
        func waitUntilFinished(seconds: Double) -> Bool {
            finished.wait(timeout: .now() + seconds) == .success
        }
    }

    // MARK: Import scratch folder

    @Test func scratchFolderIsPerProcessInsideTheDataDirectory() {
        let data = URL(fileURLWithPath: "/tmp/bow-data", isDirectory: true)
        let scratch = ImportScratchFolder(dataDirectory: data, processID: 42)
        #expect(scratch.url.path == "/tmp/bow-data/Import Scratch/42")
    }

    @Test func staleEntriesAreOnlyFoldersOfProcessesThatAreGone() {
        let names = ["42", "77", "99", "notes", "007", "-5", "0"]
        // This process is 42, 77 still runs, 99 is gone.
        let stale = ImportScratchFolder.staleEntries(names, processID: 42) { $0 == 77 }
        #expect(stale == ["99"])
    }

    @Test func anotherProcessCleaningUpNeverTouchesThisImportsCopy() throws {
        let fm = FileManager.default
        let data = fm.temporaryDirectory.appendingPathComponent("bow-scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: data) }
        let running: Set<Int32> = [1001, 1002]
        let mine = ImportScratchFolder(dataDirectory: data, processID: 1001)
        let other = ImportScratchFolder(dataDirectory: data, processID: 1002)
        let gone = ImportScratchFolder(dataDirectory: data, processID: 1003)
        let copy = mine.url.appendingPathComponent("bow-history-1/History")
        for folder in [mine.url, other.url, gone.url] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("copy".utf8).write(to: copy)
        // The other Bow launches (removing leftovers) and quits (removing its own folder) mid-import.
        other.removeStale { running.contains($0) }
        other.remove()
        #expect(fm.fileExists(atPath: copy.path))
        #expect(!fm.fileExists(atPath: other.url.path))
        #expect(!fm.fileExists(atPath: gone.url.path))
        // A Bow on another data directory (another e2e run) has its own root and never reaches this one.
        let elsewhere = ImportScratchFolder(
            dataDirectory: data.appendingPathComponent("other-run", isDirectory: true), processID: 1001)
        elsewhere.removeStale { _ in false }
        elsewhere.remove()
        #expect(fm.fileExists(atPath: copy.path))
    }

    // MARK: Bookmarks folder

    static func parsedBookmarks() throws -> ChromiumBookmarks {
        try ChromiumBookmarks.parse(data: Data(Fixture.bookmarks.utf8))
    }

    static func rows(under container: SidebarItemID, in graph: SidebarGraph, depth: Int = 0) -> [String] {
        graph.children(of: container).flatMap { item -> [String] in
            let title = item.title ?? item.tab?.savedTitle ?? ""
            return ["\(depth):\(title)"] + rows(under: item.id, in: graph, depth: depth + 1)
        }
    }

    @Test func bookmarksBecomeOnePinnedFolderKeepingTheirNesting() throws {
        try withStore { store, _ in
            let space = try #require(store.graph.activeSpace)
            let folder = ChromiumBookmarkFolder(
                spaceID: space.id, title: "Arc Bookmarks", bookmarks: try Self.parsedBookmarks())
            let applied = try ChromiumBookmarkImport.apply([folder], to: store)
            #expect(applied.addedBookmarks == 4)
            #expect(
                Self.rows(under: space.pinnedContainerID, in: store.graph) == [
                    "0:Arc Bookmarks", "1:Bookmarks bar", "2:Home", "2:Reading", "3:Deep", "4:Nested", "3:Article",
                    "1:Other bookmarks", "2:Other",
                ])
        }
    }

    @Test func importingTheSameBookmarksAgainAddsNothing() throws {
        try withStore { store, _ in
            let space = try #require(store.graph.activeSpace)
            let folder = ChromiumBookmarkFolder(
                spaceID: space.id, title: "Arc Bookmarks", bookmarks: try Self.parsedBookmarks())
            try ChromiumBookmarkImport.apply([folder], to: store)
            let before = store.graph
            let again = try ChromiumBookmarkImport.apply([folder], to: store)
            #expect(again.isEmpty)
            #expect(again.knownBookmarks == 4)
            #expect(store.graph == before)
        }
    }

    @Test func undoRemovesTheFolderButKeepsWhatThePersonAddedOrMoved() throws {
        try withStore { store, _ in
            let space = try #require(store.graph.activeSpace)
            let start = store.graph
            let folder = ChromiumBookmarkFolder(
                spaceID: space.id, title: "Arc Bookmarks", bookmarks: try Self.parsedBookmarks())
            let applied = try ChromiumBookmarkImport.apply([folder], to: store)
            try applied.undo(on: store)
            #expect(store.graph == start)

            let again = try ChromiumBookmarkImport.apply([folder], to: store)
            let graph = store.graph
            let top = try #require(graph.children(of: space.pinnedContainerID).first)
            let bar = try #require(graph.children(of: top.id).first)
            let reading = try #require(graph.children(of: bar.id).first { $0.title == "Reading" })
            let home = try #require(graph.orderedIDs().first { graph.items[$0]?.tab?.savedTitle == "Home" })
            let mine = SidebarItem.tab(url: "https://example.com/mine", title: "Mine")
            try store.apply([.insert(mine, parent: reading.id), .move(home, parent: space.pinnedContainerID)])
            try again.undo(on: store)
            let after = store.graph
            #expect(after.items[mine.id] != nil)
            #expect(after.items[home]?.parentID == space.pinnedContainerID)
            #expect(
                Self.rows(under: space.pinnedContainerID, in: after) == [
                    "0:Arc Bookmarks", "1:Bookmarks bar", "2:Reading", "3:Mine", "0:Home",
                ])
        }
    }

    @Test func undoWithASidebarImportIsOneTransaction() throws {
        try withStore { store, _ in
            let start = store.graph
            let applied = try ArcImporter.apply(
                try parsed("sidebar-client-project-phase"), plan: ArcImportPlan(), to: store)
            let imported = try #require(applied.spaceIDs.first)
            let folder = ChromiumBookmarkFolder(
                spaceID: imported, title: "Arc Bookmarks", bookmarks: try Self.parsedBookmarks())
            let bookmarks = try ChromiumBookmarkImport.apply([folder], to: store)
            try applied.undo(on: store, alongWith: bookmarks)
            #expect(store.graph == start)
        }
    }

    @Test func aRefusedUndoLeavesTheBookmarksToo() throws {
        try withStore { store, _ in
            let starter = try #require(store.graph.activeSpace)
            let applied = try ArcImporter.apply(
                try parsed("sidebar-client-project-phase"), plan: ArcImportPlan(), to: store)
            let other = try #require(applied.spaceIDs.first)
            let folder = ChromiumBookmarkFolder(
                spaceID: other, title: "Arc Bookmarks", bookmarks: try Self.parsedBookmarks())
            let bookmarks = try ChromiumBookmarkImport.apply([folder], to: store)
            #expect(!bookmarks.isEmpty)
            try store.apply([.setActiveSpace(other), .deleteSpace(starter.id)])
            let before = store.graph
            #expect(throws: ArcImportUndoError.noOtherSpaceRemains) {
                try applied.undo(on: store, alongWith: bookmarks)
            }
            #expect(store.graph == before)
        }
    }
}
