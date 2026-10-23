import Foundation
import Testing

@testable import BowCore

@Suite struct SidebarStoreTests {
    struct SimulatedCrash: Error {}

    private func file(in folder: URL) -> URL { SidebarStore.fileURL(inApplicationSupportFolder: folder) }

    private func write(_ graph: SidebarGraph, to url: URL) throws {
        try SidebarFileFormat.encode(graph).write(to: url)
    }

    private func folderContents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: Round trip

    @Test func roundTripKeepsEveryItemAndSpace() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            let store = try SidebarStore(fileURL: url)
            #expect(store.openReport.origin == .freshBecauseMissing)
            let pinned = store.graph.pinnedID
            try store.transaction {
                try store.mutate(.insert(.folder(id: "work", title: "Work"), parent: pinned))
                try store.mutate(
                    .insert(.tab(id: "docs", url: "https://docs.example.com", title: "Docs"), parent: "work"))
                try store.mutate(.insertSpace("second", title: "Second"))
                try store.mutate(.setActiveTab("docs"))
            }
            #expect(!store.hasUnsavedChanges)

            let reopened = try SidebarStore(fileURL: url)
            #expect(
                reopened.openReport == .init(origin: .loaded, migratedFrom: nil, backupURL: nil, repairs: []))
            #expect(reopened.graph == store.graph)
            #expect(!reopened.hasUnsavedChanges)
        }
    }

    @Test func roundTripOfTwelveItems() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let store = try SidebarStore(fileURL: url)
            #expect(store.graph == (try .twelveItems()))
            try store.apply([.rename("work", title: "Job")])
            let reopened = try SidebarStore(fileURL: url)
            #expect(reopened.graph.contentItemCount == 12)
            #expect(reopened.graph["work"]?.title == "Job")
            #expect(reopened.graph == store.graph)
        }
    }

    @Test func savedFileIsStableAndSortedJSON() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let first = try Data(contentsOf: url)
            let store = try SidebarStore(fileURL: url)
            try store.apply([.rename("work", title: "x"), .rename("work", title: "Work")])
            // Renaming back still commits a change-free graph, so nothing is rewritten.
            #expect(try Data(contentsOf: url) == first)
            let object = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
            #expect(object["version"] as? Int == SidebarFileFormat.currentVersion)
            let ids = (object["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
            #expect(ids == ids?.sorted())
        }
    }

    // MARK: Missing and unreadable files

    @Test func missingFileStartsFreshAndWritesOnlyWhenSaved() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("Nested/Bow").appendingPathComponent(SidebarStore.fileName)
            let store = try SidebarStore(fileURL: url)
            #expect(store.openReport.origin == .freshBecauseMissing)
            #expect(store.graph.contentItemCount == 0)
            #expect(store.graph.spaces.count == 1)
            #expect(store.hasUnsavedChanges)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            try store.save()
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(!store.hasUnsavedChanges)
            #expect(try SidebarStore(fileURL: url).graph == store.graph)
        }
    }

    @Test(arguments: [
        ("garbage", Data([0xFF, 0x00, 0x13, 0x37])),
        ("empty", Data()),
        ("array", Data("[1, 2]".utf8)),
        ("no version", Data(#"{"items": []}"#.utf8)),
        ("boolean version", Data(#"{"version": true}"#.utf8)),
        ("newer version", Data(#"{"version": 99, "items": []}"#.utf8)),
        ("bad shape", Data(#"{"version": 1, "items": "nope", "spaces": []}"#.utf8)),
        ("no items", Data(#"{"version": 1, "spaces": []}"#.utf8)),
    ])
    func unreadableFileIsSetAsideUntouchedAndAFreshSidebarStarts(name: String, contents: Data) throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try contents.write(to: url)
            let store = try SidebarStore(fileURL: url)
            guard case .freshAfterSettingAside(let aside, let reason) = store.openReport.origin else {
                Issue.record("\(name): expected the file to be set aside, got \(store.openReport.origin)")
                return
            }
            #expect(!reason.isEmpty)
            #expect(aside.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(aside.lastPathComponent.hasPrefix("Sidebar.unreadable-"))
            #expect(try Data(contentsOf: aside) == contents)
            #expect(store.graph.contentItemCount == 0)

            // Saving writes a new file and leaves the set-aside copy alone.
            try store.save()
            #expect(try Data(contentsOf: aside) == contents)
            #expect(try SidebarStore(fileURL: url).openReport.origin == .loaded)
        }
    }

    @Test func truncatedFileIsSetAside() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            let full = try SidebarFileFormat.encode(try .twelveItems())
            try full.prefix(full.count / 2).write(to: url)
            let store = try SidebarStore(fileURL: url)
            guard case .freshAfterSettingAside = store.openReport.origin else {
                Issue.record("expected set aside, got \(store.openReport.origin)")
                return
            }
        }
    }

    @Test func secondUnreadableFileNeverReplacesTheFirstSetAsideCopy() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try Data("first".utf8).write(to: url)
            _ = try SidebarStore(fileURL: url)
            try Data("second".utf8).write(to: url)
            _ = try SidebarStore(fileURL: url)
            let asides = try folderContents(folder).filter { $0.hasPrefix("Sidebar.unreadable-") }
            #expect(asides.count == 2)
            let contents = try Set(
                asides.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) })
            #expect(contents == ["first", "second"])
        }
    }

    @Test func unreadableFileThatCannotBeSetAsideStopsTheStoreInsteadOfBeingOverwritten() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try Data("broken".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            #expect {
                _ = try SidebarStore(fileURL: url)
            } throws: { error in
                if case .unreadableFileNotSetAside = error as? SidebarStoreError { return true }
                return false
            }
            #expect(try Data(contentsOf: url) == Data("broken".utf8))
        }
    }

    // MARK: Versions

    /// The shape of an imaginary version 0, where tabs stored `url` and `title` at the top of the item.
    private let versionZero = #"""
        {
          "version": 0,
          "favoritesContainerID": "favorites",
          "activeSpaceID": "home",
          "spaces": [{"id": "home", "title": "Home", "pinnedContainerID": "pinned", "unpinnedContainerID": "unpinned"}],
          "items": [
            {"id": "favorites", "childrenIDs": [], "data": {"kind": "container", "container": {"kind": "favorites"}}},
            {"id": "pinned", "childrenIDs": ["old-tab"], "data": {"kind": "container", "container": {"kind": "pinned"}}},
            {"id": "unpinned", "childrenIDs": [], "data": {"kind": "container", "container": {"kind": "unpinned"}}},
            {"id": "old-tab", "parentID": "pinned", "childrenIDs": [], "url": "https://old.example", "title": "Old",
             "data": {"kind": "tab"}}
          ]
        }
        """#

    private let zeroToOne = SidebarFileFormat.Migration(from: 0) { object in
        guard var items = object["items"] as? [[String: Any]] else { throw SimulatedCrash() }
        for index in items.indices {
            guard let url = items[index].removeValue(forKey: "url") as? String else { continue }
            let title = items[index].removeValue(forKey: "title") as? String ?? ""
            items[index]["data"] = ["kind": "tab", "tab": ["savedURL": url, "savedTitle": title]]
        }
        object["items"] = items
    }

    @Test func olderVersionMigratesForwardAndKeepsACopyOfTheOriginal() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try Data(versionZero.utf8).write(to: url)
            let store = try SidebarStore(fileURL: url, migrations: [zeroToOne], writer: AtomicFileWriter())
            #expect(store.openReport.origin == .loaded)
            #expect(store.openReport.migratedFrom == 0)
            #expect(store.openReport.repairs == [])
            #expect(store.graph["old-tab"]?.tab == SidebarTab(savedURL: "https://old.example", savedTitle: "Old"))
            #expect(store.hasUnsavedChanges)

            let backup = try #require(store.openReport.backupURL)
            #expect(backup.lastPathComponent == "Sidebar.version-0.json")
            #expect(try Data(contentsOf: backup) == Data(versionZero.utf8))

            try store.save()
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(saved?["version"] as? Int == 1)
            #expect(try SidebarStore(fileURL: url).graph == store.graph)
        }
    }

    @Test func olderVersionWithoutAMigrationIsSetAside() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try Data(versionZero.utf8).write(to: url)
            let store = try SidebarStore(fileURL: url)
            guard case .freshAfterSettingAside(_, let reason) = store.openReport.origin else {
                Issue.record("expected set aside, got \(store.openReport.origin)")
                return
            }
            #expect(reason.contains("no migration from version 0"))
        }
    }

    @Test func migrationsRunInOrderAcrossSeveralVersions() throws {
        let addMarker = SidebarFileFormat.Migration(from: 1) { object in object["marker"] = "added by 1 to 2" }
        let decoded = try SidebarFileFormat.decode(
            Data(versionZero.utf8), currentVersion: 2, migrations: [addMarker, zeroToOne])
        #expect(decoded.migratedFrom == 0)
        #expect(decoded.graph["old-tab"]?.tab?.savedURL == "https://old.example")
        #expect(throws: SidebarFileFormat.ReadError.noMigration(from: 1)) {
            try SidebarFileFormat.decode(Data(versionZero.utf8), currentVersion: 2, migrations: [zeroToOne])
        }
    }

    // MARK: Transactions

    @Test func nestedTransactionIsRefusedAndRollsBackTheOuterOne() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: file(in: folder))
            let pinned = store.graph.pinnedID
            let before = store.graph

            try store.beginTransaction()
            #expect(throws: SidebarStoreError.nestedTransaction) { try store.beginTransaction() }
            #expect(store.isInTransaction)
            store.rollbackTransaction()

            #expect(throws: SidebarStoreError.nestedTransaction) {
                try store.transaction {
                    try store.mutate(.insert(.tab(id: "a", url: "https://a.example"), parent: pinned))
                    try store.transaction {}
                }
            }
            #expect(!store.isInTransaction)
            #expect(store.graph == before)
            #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }

    @Test func changesOutsideATransactionAreRefused() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: file(in: folder))
            #expect(throws: SidebarStoreError.noOpenTransaction) { try store.mutate(.insertSpace("x", title: "X")) }
            #expect(throws: SidebarStoreError.noOpenTransaction) { try store.commitTransaction() }
            try store.beginTransaction()
            #expect(throws: SidebarStoreError.transactionInProgress) { try store.save() }
            #expect(throws: SidebarStoreError.transactionInProgress) { try store.repair() }
            store.rollbackTransaction()
        }
    }

    @Test func uncommittedChangesAreInvisibleAndARefusedMutationKeepsTheTransactionOpen() throws {
        try withTemporaryFolder { folder in
            let store = try SidebarStore(fileURL: file(in: folder))
            let pinned = store.graph.pinnedID
            try store.beginTransaction()
            try store.mutate(.insert(.tab(id: "a", url: "https://a.example"), parent: pinned))
            #expect(store.graph["a"] == nil)
            #expect(store.transactionGraph?["a"] != nil)

            #expect(throws: SidebarStoreError.itemAlreadyExists("a")) {
                try store.mutate(.insert(.tab(id: "a", url: "https://b.example"), parent: pinned))
            }
            #expect(store.transactionGraph?["a"]?.tab?.savedURL == "https://a.example")
            try store.commitTransaction()
            #expect(store.graph["a"] != nil)
            #expect(try SidebarStore(fileURL: store.fileURL).graph["a"] != nil)
        }
    }

    @Test func aFailingStepRollsBackTheWholeTransaction() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let original = try Data(contentsOf: url)
            let store = try SidebarStore(fileURL: url)
            #expect(throws: SidebarStoreError.itemNotFound("missing")) {
                try store.apply([.delete("work"), .delete("missing")])
            }
            #expect(store.graph["work"] != nil)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    // MARK: Crash safety

    @Test func crashBeforeTheRenameLeavesThePreviousFileIntact() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let original = try Data(contentsOf: url)
            let crashing = AtomicFileWriter { stage in if stage == .temporaryFileWritten { throw SimulatedCrash() } }
            let store = try SidebarStore(fileURL: url, migrations: [], writer: crashing)

            #expect {
                try store.apply([.delete("work")])
            } throws: { error in
                if case .saveFailed = error as? SidebarStoreError { return true }
                return false
            }
            // The change is kept in memory and still marked unsaved; the file is the old one.
            #expect(store.graph["work"] == nil)
            #expect(store.hasUnsavedChanges)
            #expect(try Data(contentsOf: url) == original)
            #expect(try folderContents(folder).contains { $0.hasSuffix(".tmp") })

            // After the "crash", the next launch reads the previous sidebar and clears the leftover.
            let relaunched = try SidebarStore(fileURL: url)
            #expect(relaunched.graph == (try .twelveItems()))
            #expect(try folderContents(folder) == ["Sidebar.json"])
        }
    }

    @Test func crashAfterTheRenameLeavesTheNewFile() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let crashing = AtomicFileWriter { stage in if stage == .renamed { throw SimulatedCrash() } }
            let store = try SidebarStore(fileURL: url, migrations: [], writer: crashing)
            #expect(throws: SidebarStoreError.self) { try store.apply([.delete("work")]) }
            let relaunched = try SidebarStore(fileURL: url)
            #expect(relaunched.graph["work"] == nil)
            #expect(relaunched.graph.integrityProblems().isEmpty)
        }
    }

    @Test func leftoverPartialTemporaryFileIsIgnored() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let leftover = folder.appendingPathComponent(".Sidebar.json.\(UUID().uuidString).tmp")
            try Data(#"{"version": 1, "ite"#.utf8).write(to: leftover)
            let store = try SidebarStore(fileURL: url)
            #expect(store.openReport.origin == .loaded)
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
        }
    }

    @Test func failedWriteKeepsTheChangeUnsavedUntilSaveSucceeds() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let original = try Data(contentsOf: url)
            let store = try SidebarStore(fileURL: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

            #expect(throws: SidebarStoreError.self) { try store.apply([.rename("work", title: "Job")]) }
            #expect(store.graph["work"]?.title == "Job")
            #expect(store.hasUnsavedChanges)
            #expect(try Data(contentsOf: url) == original)

            // Once the folder is writable again, the next commit retries the write even if it changes nothing.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try store.transaction {}
            #expect(!store.hasUnsavedChanges)
            #expect(try SidebarStore(fileURL: url).graph["work"]?.title == "Job")
        }
    }

    @Test func saveOnQuitWritesWhatAFailedCommitLeftUnsaved() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            try write(try .twelveItems(), to: url)
            let store = try SidebarStore(fileURL: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
            #expect(throws: SidebarStoreError.self) { try store.apply([.delete("news")]) }
            #expect(throws: SidebarStoreError.self) { try store.save() }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try store.save()
            #expect(!store.hasUnsavedChanges)
            #expect(try SidebarStore(fileURL: url).graph["news"] == nil)
        }
    }

    @Test func oneUnreadableRecordIsSkippedAndTheRestRecovered() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            var object = try #require(
                try JSONSerialization.jsonObject(with: SidebarFileFormat.encode(try .twelveItems())) as? [String: Any])
            // The "work" folder becomes a kind this build does not know, and Favorites loses its ID.
            var items = try #require(object["items"] as? [[String: Any]])
            let index = try #require(items.firstIndex { $0["id"] as? String == "work" })
            items[index]["data"] = ["kind": "easel"]
            object["items"] = items
            object["favoritesContainerID"] = nil
            let original = try JSONSerialization.data(withJSONObject: object)
            try original.write(to: url)

            let store = try SidebarStore(fileURL: url)
            #expect(store.openReport.origin == .loaded)
            #expect(store.openReport.repairs.contains(.skippedUnreadableRecords(1)))
            // Only the unreadable record is missing; what was inside it is recovered, and the old Favorites tabs too.
            #expect(store.graph["work"] == nil)
            #expect(store.graph.contentItemCount == 12)
            let recovered = try #require(store.graph[.recentlyRecovered]?.childrenIDs)
            #expect(Set(recovered) == ["docs", "deep", "fav-mail", "fav-cal"])
            #expect(store.graph["deep"]?.childrenIDs == ["deep-tab"])

            let backup = try #require(store.openReport.backupURL)
            #expect(backup.lastPathComponent.hasPrefix("Sidebar.repaired-"))
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    // MARK: Repair and tab truth

    @Test func damagedFileIsRepairedOnOpenWithoutLosingItems() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            var damaged = try SidebarGraph.twelveItems()
            damaged.items["pinned"]?.childrenIDs.removeAll { $0 == "work" }
            damaged.items["work"]?.parentID = "gone"
            try write(damaged, to: url)

            let store = try SidebarStore(fileURL: url)
            #expect(store.openReport.origin == .loaded)
            #expect(store.openReport.repairs.contains(.recovered("work")))
            #expect(store.graph[.recentlyRecovered]?.childrenIDs == ["work"])
            #expect(store.graph.contentItemCount == 13)
            #expect(store.hasUnsavedChanges)
            let backup = try #require(store.openReport.backupURL)
            #expect(try SidebarStore(fileURL: url).openReport.backupURL != backup)
            try store.save()
            let reopened = try SidebarStore(fileURL: url)
            #expect(reopened.openReport.repairs.isEmpty)
            #expect(reopened.openReport.backupURL == nil)
            // The copy of the damaged file is still there, untouched.
            #expect(try SidebarStore(fileURL: backup).openReport.repairs.contains(.recovered("work")))
        }
    }

    @Test func duplicateItemIDsInTheFileKeepTheFirst() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            var object = try #require(
                try JSONSerialization.jsonObject(with: SidebarFileFormat.encode(try .twelveItems())) as? [String: Any])
            var items = try #require(object["items"] as? [[String: Any]])
            var copy = try #require(items.first { $0["id"] as? String == "news" })
            copy["title"] = "Impostor"
            items.append(copy)
            object["items"] = items
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            let store = try SidebarStore(fileURL: url)
            #expect(store.openReport.repairs == [.droppedDuplicateItem("news")])
            #expect(store.graph["news"]?.title == nil)
        }
    }

    @Test func onlyTheSavedAddressIsStoredForATab() throws {
        try withTemporaryFolder { folder in
            let url = file(in: folder)
            var object = try #require(
                try JSONSerialization.jsonObject(with: SidebarFileFormat.encode(try .twelveItems())) as? [String: Any])
            // A field for the live page (as another build might have written) is ignored and never saved back.
            var items = try #require(object["items"] as? [[String: Any]])
            let index = try #require(items.firstIndex { $0["id"] as? String == "docs" })
            items[index]["data"] = [
                "kind": "tab",
                "tab": ["savedURL": "https://docs.example.com", "savedTitle": "Docs", "liveURL": "https://elsewhere"],
            ]
            object["items"] = items
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            let store = try SidebarStore(fileURL: url)
            #expect(store.graph["docs"]?.tab == SidebarTab(savedURL: "https://docs.example.com", savedTitle: "Docs"))
            try store.apply([.rename("docs", title: "Renamed")])
            let saved = try String(contentsOf: url, encoding: .utf8)
            #expect(!saved.contains("elsewhere"))
            #expect(!saved.contains("liveURL"))
            let tab = try #require(
                ((try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])?["items"]
                    as? [[String: Any]])?
                    .first { $0["id"] as? String == "docs" }?["data"] as? [String: Any])
            #expect(Set((tab["tab"] as? [String: Any])?.keys ?? [:].keys) == ["savedURL", "savedTitle"])
        }
    }
}
