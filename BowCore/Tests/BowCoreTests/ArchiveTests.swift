import Foundation
import Testing

@testable import BowCore

@Suite struct ArchiveTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let hour: TimeInterval = 3_600

    // MARK: Threshold menu

    @Test func menuHasExactlyTheSevenChoices() {
        #expect(
            AutoArchiveThreshold.allCases.map(\.title) == [
                "Never", "1 hour", "6 hours", "12 hours", "24 hours", "7 days", "30 days",
            ])
        #expect(
            AutoArchiveThreshold.allCases.map(\.interval) == [
                nil, hour, 6 * hour, 12 * hour, 24 * hour, 7 * 24 * hour, 30 * 24 * hour,
            ])
    }

    @Test func thresholdsArePerProfileWithADefault() throws {
        var settings = AutoArchiveSettings()
        #expect(settings.threshold(for: "work") == .twelveHours)
        settings.setThreshold(.sevenDays, for: "work")
        #expect(settings.threshold(for: "work") == .sevenDays)
        #expect(settings.threshold(for: "home") == .twelveHours)

        let decoded = try JSONDecoder().decode(AutoArchiveSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func savedValueOffTheMenuFallsBackToTheDefault() throws {
        let json = #"{"thresholds":{"work":"2h","home":"30d"}}"#
        let settings = try JSONDecoder().decode(AutoArchiveSettings.self, from: Data(json.utf8))
        #expect(settings.threshold(for: "work") == .twelveHours)
        #expect(settings.threshold(for: "home") == .thirtyDays)
        // The unknown value is kept when the settings are saved again, for the build that wrote it.
        let saved = try String(decoding: JSONEncoder().encode(settings), as: UTF8.self)
        #expect(saved.contains("2h"))
    }

    // MARK: Policy

    private func expired(
        _ graph: SidebarGraph, idle: [SidebarItemID: TimeInterval], now: TimeInterval = 0,
        threshold: AutoArchiveThreshold = .twelveHours, keeping: Set<SidebarItemID> = []
    ) -> [SidebarItemID] {
        let time = ManualTimeSource(start.addingTimeInterval(now))
        let lastActive = idle.mapValues { start.addingTimeInterval(now - $0) }
        return AutoArchivePolicy(time: time).expiredItems(
            in: graph, lastActive: lastActive, threshold: { _ in threshold }, keeping: keeping)
    }

    @Test func archivesTodayTabsIdleAtLeastTheThreshold() throws {
        let graph = try SidebarGraph.twelveItems()
        let result = expired(graph, idle: ["search": 12 * hour, "news": 13 * hour, "renamed": 99 * hour])
        // "news" is the selected tab and "renamed" is pinned.
        #expect(result == ["search"])
        #expect(expired(graph, idle: ["search": 12 * hour - 1]).isEmpty)
    }

    @Test func pinnedTabsAndFavoritesAreNeverArchived() throws {
        let graph = try SidebarGraph.twelveItems()
        let ancient = Dictionary(
            uniqueKeysWithValues: ["fav-mail", "docs", "deep-tab", "left", "right", "renamed"].map {
                (SidebarItemID($0), 1_000 * hour)
            })
        #expect(expired(graph, idle: ancient, threshold: .oneHour).isEmpty)
    }

    @Test func neverThresholdArchivesNothing() throws {
        let graph = try SidebarGraph.twelveItems()
        #expect(expired(graph, idle: ["search": 10_000 * hour], threshold: .never).isEmpty)
    }

    @Test func theSelectedTabAndKeptTabsStay() throws {
        let graph = try SidebarGraph.twelveItems().applying([
            .insert(.tab(id: "music", url: "https://music.example.com"), parent: "unpinned")
        ])
        let idle: [SidebarItemID: TimeInterval] = ["news": 50 * hour, "search": 50 * hour, "music": 50 * hour]
        #expect(expired(graph, idle: idle, keeping: ["music"]) == ["search"])
    }

    @Test func tabsWithNoActivityRecordStay() throws {
        let graph = try SidebarGraph.twelveItems()
        #expect(expired(graph, idle: [:]).isEmpty)
    }

    @Test func aSplitMovesWholeOnlyWhenEveryTabExpired() throws {
        let graph = try SidebarGraph.sample().applying([
            .insert(.split(id: "split"), parent: "unpinned"),
            .insert(.tab(id: "left", url: "https://left.example.com"), parent: "split"),
            .insert(.tab(id: "right", url: "https://right.example.com"), parent: "split"),
        ])
        #expect(expired(graph, idle: ["left": 20 * hour, "right": hour]).isEmpty)
        #expect(expired(graph, idle: ["left": 20 * hour, "right": 20 * hour]) == ["split"])
    }

    @Test func eachSpaceUsesItsOwnThreshold() throws {
        let graph = try SidebarGraph.sample().applying([
            .insertSpace("other", title: "Other"),
            .insert(.tab(id: "a", url: "https://a.example.com"), parent: "unpinned"),
        ])
        let otherUnpinned = try #require(graph.space("other")).unpinnedContainerID
        let graph2 = try graph.applying([.insert(.tab(id: "b", url: "https://b.example.com"), parent: otherUnpinned)])
        let result = AutoArchivePolicy(time: ManualTimeSource(start)).expiredItems(
            in: graph2,
            lastActive: ["a": start.addingTimeInterval(-2 * hour), "b": start.addingTimeInterval(-2 * hour)],
            threshold: { $0.id == "home" ? .oneHour : .never })
        #expect(result == ["a"])
    }

    // MARK: Entries and put back

    @Test func putBackRestoresPositionTitleAndSubtree() throws {
        try withTemporaryFolder { folder in
            let sidebar = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            let unpinned = sidebar.graph.unpinnedID
            try sidebar.apply([
                .insert(.tab(id: "first", url: "https://1.example.com"), parent: unpinned),
                .insert(.split(id: "split", orientation: .vertical), parent: unpinned),
                .insert(.tab(id: "l", url: "https://l.example.com", title: "L", customTitle: "Mine"), parent: "split"),
                .insert(.tab(id: "r", url: "https://r.example.com"), parent: "split"),
                .insert(.tab(id: "last", url: "https://last.example.com"), parent: unpinned),
            ])
            let before = sidebar.graph
            let time = ManualTimeSource(start)
            let service = ArchiveService(sidebar: sidebar, archive: archived, time: time)

            let entries = try service.archive(["split"], reason: .manual)
            #expect(entries.count == 1)
            #expect(sidebar.graph.items["split"] == nil && sidebar.graph.items["l"] == nil)
            #expect(sidebar.graph.children(of: unpinned).map(\.id) == ["first", "last"])

            // Something else moved around in the meantime.
            try sidebar.apply([.insert(.tab(id: "new", url: "https://new.example.com"), parent: unpinned, index: 0)])
            try service.putBack("split")
            #expect(sidebar.graph.children(of: unpinned).map(\.id) == ["new", "split", "first", "last"])
            #expect(sidebar.graph.items["split"] == before.items["split"])
            #expect(sidebar.graph.items["l"] == before.items["l"])
            #expect(sidebar.graph.items["r"] == before.items["r"])
            #expect(archived.entries.isEmpty)
            #expect(sidebar.graph.integrityProblems().isEmpty)
        }
    }

    @Test func putBackFallsBackToTopOfTheSpacesTodayWhenTheFolderIsGone() throws {
        try withTemporaryFolder { folder in
            let sidebar = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            let unpinned = sidebar.graph.unpinnedID
            try sidebar.apply([
                .insert(.folder(id: "group", title: "Group"), parent: unpinned),
                .insert(.tab(id: "t", url: "https://t.example.com"), parent: "group"),
                .insert(.tab(id: "other", url: "https://o.example.com"), parent: unpinned),
            ])
            let service = ArchiveService(sidebar: sidebar, archive: archived, time: ManualTimeSource(start))
            try service.archive(["t"], reason: .auto)
            try sidebar.apply([.delete("group")])
            try service.putBack("t")
            #expect(sidebar.graph.children(of: unpinned).map(\.id) == ["t", "other"])
        }
    }

    @Test func putBackWhenTheSpaceIsGoneUsesTheFirstSpace() throws {
        try withTemporaryFolder { folder in
            let sidebar = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            try sidebar.apply([.insertSpace("temp", title: "Temp")])
            let tempUnpinned = try #require(sidebar.graph.space("temp")).unpinnedContainerID
            try sidebar.apply([.insert(.tab(id: "t", url: "https://t.example.com"), parent: tempUnpinned)])
            let service = ArchiveService(sidebar: sidebar, archive: archived, time: ManualTimeSource(start))
            let entry = try #require(try service.archive(["t"], reason: .manual).first)
            #expect(entry.source.spaceID == "temp")
            try sidebar.apply([.deleteSpace("temp")])
            try service.putBack("t")
            #expect(sidebar.graph.children(of: sidebar.graph.spaces[0].unpinnedContainerID).map(\.id) == ["t"])
        }
    }

    @Test func pinnedItemsFavoritesAndSectionsCannotBeArchived() throws {
        try withTemporaryFolder { folder in
            let sidebar = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            try sidebar.apply([
                .insert(
                    .tab(id: "fav", url: "https://f.example.com"),
                    parent: try #require(sidebar.graph.favoritesContainerID(for: .default))),
                .insert(.tab(id: "pin", url: "https://p.example.com"), parent: sidebar.graph.pinnedID),
                .insert(.tab(id: "today", url: "https://t.example.com"), parent: sidebar.graph.unpinnedID),
            ])
            let service = ArchiveService(sidebar: sidebar, archive: archived, time: ManualTimeSource(start))
            for id: SidebarItemID in ["fav", "pin", "unpinned", "missing"] {
                #expect(throws: ArchiveError.self) { try service.archive([id], reason: .manual) }
            }
            // One bad item refuses the whole request.
            #expect(throws: ArchiveError.self) { try service.archive(["today", "pin"], reason: .manual) }
            #expect(sidebar.graph.items["today"] != nil)
            #expect(archived.entries.isEmpty)
        }
    }

    @Test func archiveRecordsReasonSourceAndTime() throws {
        try withTemporaryFolder { folder in
            let sidebar = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            let space = sidebar.graph.firstSpace
            try sidebar.apply([
                .insert(.tab(id: "a", url: "https://a.example.com"), parent: space.unpinnedContainerID),
                .insert(.tab(id: "b", url: "https://b.example.com"), parent: space.unpinnedContainerID),
            ])
            let time = ManualTimeSource(start)
            let service = ArchiveService(sidebar: sidebar, archive: archived, time: time)
            try service.archive(["a"], reason: .manual)
            time.advance(by: hour)
            try service.archive(["b"], reason: .auto)

            #expect(archived.entries.map(\.id) == ["b", "a"])
            let b = try #require(archived.entry(for: "b"))
            #expect(b.reason == .auto && b.archivedAt == start.addingTimeInterval(hour))
            #expect(b.source == .init(spaceID: space.id.rawValue, parentID: space.unpinnedContainerID, index: 0))
            #expect(archived.entries(reason: .manual).map(\.id) == ["a"])
            #expect(archived.entries(inSpace: space.id.rawValue).count == 2)
            #expect(archived.entries(inSpace: "nope").isEmpty)
        }
    }

    // MARK: The scenario from the work item

    @Test func thirteenHoursLaterOnlyTheIdleTabIsArchivedAndReopensExactly() throws {
        try withTemporaryFolder { folder in
            let sidebar = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            let unpinned = sidebar.graph.unpinnedID
            try sidebar.apply([
                .insert(.tab(id: "A", url: "https://a.example.com"), parent: unpinned),
                .insert(.tab(id: "B", url: "https://b.example.com", title: "B"), parent: unpinned),
                .setActiveTab("A"),
            ])
            let time = ManualTimeSource(start)
            let service = ArchiveService(sidebar: sidebar, archive: archived, time: time)
            let policy = AutoArchivePolicy(time: time)
            let before = sidebar.graph
            let lastActive: [SidebarItemID: Date] = ["A": start, "B": start]

            time.advance(by: 11 * hour)
            #expect(
                try service.runAutoArchive(policy: policy, lastActive: lastActive, threshold: { _ in .twelveHours })
                    .isEmpty)

            time.advance(by: 2 * hour)
            let done = try service.runAutoArchive(
                policy: policy, lastActive: lastActive, threshold: { _ in .twelveHours })
            #expect(done.map(\.id) == ["B"])
            #expect(sidebar.graph.children(of: unpinned).map(\.id) == ["A"])
            #expect(archived.entries.map(\.id) == ["B"])

            try service.putBack("B")
            #expect(sidebar.graph == before)
        }
    }

    // MARK: Archive file

    @Test func archiveSurvivesReopeningAndLivesOutsideTheSidebarFile() throws {
        try withTemporaryFolder { folder in
            let sidebarURL = SidebarStore.fileURL(inApplicationSupportFolder: folder)
            let archiveURL = ArchiveStore.fileURL(inApplicationSupportFolder: folder)
            let sidebar = try SidebarStore(fileURL: sidebarURL)
            let archived = try ArchiveStore(fileURL: archiveURL)
            try sidebar.apply([
                .insert(
                    .tab(id: "t", url: "https://t.example.com/?q=a b", title: "T", customTitle: "Mine"),
                    parent: sidebar.graph.unpinnedID)
            ])
            try ArchiveService(sidebar: sidebar, archive: archived, time: ManualTimeSource(start))
                .archive(["t"], reason: .auto)

            let reopened = try ArchiveStore(fileURL: archiveURL)
            #expect(reopened.openReport.origin == .loaded)
            #expect(reopened.entries == archived.entries)
            #expect(reopened.entries.first?.item.title == "Mine")

            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any])
            #expect(object["version"] as? Int == ArchiveFileFormat.currentVersion)
            #expect((object["items"] as? [Any])?.count == 1)
            #expect(try !String(contentsOf: sidebarURL, encoding: .utf8).contains("t.example.com"))
            #expect(try SidebarStore(fileURL: sidebarURL).graph.items["t"] == nil)
        }
    }

    @Test func archivingAnItemTwiceKeepsOneEntry() throws {
        try withTemporaryFolder { folder in
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            let graph = try SidebarGraph.sample().applying([
                .insert(.tab(id: "t", url: "https://t.example.com"), parent: "unpinned")
            ])
            let first = try ArchivedEntry.capture("t", from: graph, reason: .auto, at: start)
            let second = try ArchivedEntry.capture("t", from: graph, reason: .manual, at: start.addingTimeInterval(5))
            try archived.add([first])
            try archived.add([second])
            #expect(archived.entries == [second])
        }
    }

    @Test func interruptedArchiveAndPutBackNeverLoseTheItem() throws {
        try withTemporaryFolder { folder in
            let sidebar = try SidebarStore(fileURL: SidebarStore.fileURL(inApplicationSupportFolder: folder))
            let archived = try ArchiveStore(fileURL: ArchiveStore.fileURL(inApplicationSupportFolder: folder))
            try sidebar.apply([.insert(.tab(id: "t", url: "https://t.example.com"), parent: sidebar.graph.unpinnedID)])
            let service = ArchiveService(sidebar: sidebar, archive: archived, time: ManualTimeSource(start))

            // Crash after the archive was written but before the sidebar changed: the item is in both places.
            try archived.add([try ArchivedEntry.capture("t", from: sidebar.graph, reason: .auto, at: start)])
            try service.archive(["t"], reason: .auto)
            #expect(archived.entries.count == 1 && sidebar.graph.items["t"] == nil)

            // Crash after the sidebar got the item back but before the entry was forgotten.
            try sidebar.apply(try #require(archived.entry(for: "t")).putBackMutations(into: sidebar.graph))
            try service.putBack("t")
            #expect(archived.entries.isEmpty && sidebar.graph.items["t"] != nil)
        }
    }

    @Test func aFailedWriteLeavesTheArchiveAsItWas() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent("sub/ArchivedItems.json")
            var writer = AtomicFileWriter()
            struct Crash: Error {}
            let archived = try ArchiveStore(fileURL: url, migrations: [], writer: writer)
            let graph = try SidebarGraph.sample().applying([
                .insert(.tab(id: "t", url: "https://t.example.com"), parent: "unpinned")
            ])
            let entry = try ArchivedEntry.capture("t", from: graph, reason: .auto, at: start)
            try archived.add([entry])

            writer.crashPoint = { _ in throw Crash() }
            let failing = try ArchiveStore(fileURL: url, migrations: [], writer: writer)
            #expect(failing.entries == [entry])
            #expect(throws: ArchiveError.self) { try failing.remove(["t"]) }
            #expect(failing.entries == [entry])
            #expect(try ArchiveStore(fileURL: url).entries == [entry])
        }
    }

    @Test func aFileFromANewerBuildIsRefusedAndLeftWhereItIs() throws {
        try withTemporaryFolder { folder in
            let url = ArchiveStore.fileURL(inApplicationSupportFolder: folder)
            let newer = Data(#"{"version":99,"items":[]}"#.utf8)
            try newer.write(to: url)
            let refused = ArchiveError.fileFromNewerBuild(version: 99, readable: ArchiveFileFormat.currentVersion)
            #expect(throws: refused) { try ArchiveStore(fileURL: url) }
            #expect(try Data(contentsOf: url) == newer)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [url.lastPathComponent])
        }
    }

    @Test func corruptBytesAreSetAsideNotOverwritten() throws {
        try withTemporaryFolder { folder in
            let url = ArchiveStore.fileURL(inApplicationSupportFolder: folder)
            let corrupt = Data("not json".utf8)
            try corrupt.write(to: url)
            let store = try ArchiveStore(fileURL: url)
            guard case .freshAfterSettingAside(let aside, _) = store.openReport.origin else {
                Issue.record("expected the file to be set aside")
                return
            }
            #expect(try Data(contentsOf: aside) == corrupt)
            #expect(store.entries.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func anOlderFileMigratesWhenTheStoreOpens() throws {
        try withTemporaryFolder { folder in
            let url = ArchiveStore.fileURL(inApplicationSupportFolder: folder)
            let graph = try SidebarGraph.sample().applying([
                .insert(.tab(id: "t", url: "https://t.example.com"), parent: "unpinned")
            ])
            let entry = try ArchivedEntry.capture("t", from: graph, reason: .auto, at: start)
            var object = try #require(
                JSONSerialization.jsonObject(with: ArchiveFileFormat.encode([entry])) as? [String: Any])
            object["version"] = 1
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            let migration = SidebarFileFormat.Migration(from: 1) { _ in }
            let store = try ArchiveStore(
                fileURL: url, currentVersion: 2, migrations: [migration], writer: AtomicFileWriter())
            #expect(store.openReport.origin == .loaded)
            #expect(store.openReport.migratedFrom == 1)
            #expect(store.entries == [entry])
            #expect(store.openReport.backupURL != nil)
        }
    }

    @Test func oneDamagedEntryIsSkippedAndTheFileIsCopiedFirst() throws {
        try withTemporaryFolder { folder in
            let url = ArchiveStore.fileURL(inApplicationSupportFolder: folder)
            let graph = try SidebarGraph.sample().applying([
                .insert(.tab(id: "t", url: "https://t.example.com"), parent: "unpinned")
            ])
            let good = try ArchivedEntry.capture("t", from: graph, reason: .auto, at: start)
            var object = try #require(
                JSONSerialization.jsonObject(with: ArchiveFileFormat.encode([good])) as? [String: Any])
            object["items"] = (object["items"] as? [Any] ?? []) + [["junk": true]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)

            let store = try ArchiveStore(fileURL: url)
            #expect(store.entries == [good])
            #expect(store.openReport.skippedRecordCount == 1)
            let backup = try #require(store.openReport.backupURL)
            #expect(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    @Test func olderFilesMigrateOneVersionAtATime() throws {
        let graph = try SidebarGraph.sample().applying([
            .insert(.tab(id: "t", url: "https://t.example.com"), parent: "unpinned")
        ])
        let entry = try ArchivedEntry.capture("t", from: graph, reason: .auto, at: start)
        var object = try #require(
            JSONSerialization.jsonObject(with: ArchiveFileFormat.encode([entry])) as? [String: Any])
        object["version"] = 1
        let data = try JSONSerialization.data(withJSONObject: object)
        let migration = SidebarFileFormat.Migration(from: 1) { $0["migrated"] = true }
        let decoded = try ArchiveFileFormat.decode(data, currentVersion: 2, migrations: [migration])
        #expect(decoded.migratedFrom == 1)
        #expect(decoded.entries == [entry])
        #expect(throws: ArchiveFileFormat.ReadError.noMigration(from: 1)) {
            try ArchiveFileFormat.decode(data, currentVersion: 2, migrations: [])
        }
    }

    @Test func aTabInsideASplitCannotBeArchivedAlone() throws {
        let graph = try SidebarGraph.sample().applying([
            .insert(.split(id: "split"), parent: "unpinned"),
            .insert(.tab(id: "l", url: "https://l.example.com"), parent: "split"),
        ])
        #expect(throws: ArchiveError.self) { try ArchivedEntry.capture("l", from: graph, reason: .manual, at: start) }
    }

    @Test func aFileThatCannotBeReadIsRefusedAndNotSetAside() throws {
        try withTemporaryFolder { folder in
            let url = ArchiveStore.fileURL(inApplicationSupportFolder: folder)
            try ArchiveFileFormat.encode([]).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            #expect {
                try ArchiveStore(fileURL: url)
            } throws: { error in
                guard case .unreadableFileNotSetAside(let reason) = error as? ArchiveError else { return false }
                return reason.hasPrefix("reading failed")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [url.lastPathComponent])
        }
    }

    @Test func aRepairedFileIsCopiedOnceAndDuplicatesAreNotDamage() throws {
        try withTemporaryFolder { folder in
            let url = ArchiveStore.fileURL(inApplicationSupportFolder: folder)
            let graph = try SidebarGraph.sample().applying([
                .insert(.tab(id: "t", url: "https://t.example.com"), parent: "unpinned")
            ])
            let good = try ArchivedEntry.capture("t", from: graph, reason: .auto, at: start)
            try ArchiveFileFormat.encode([good, good]).write(to: url)
            let duplicated = try ArchiveStore(fileURL: url)
            #expect(duplicated.entries == [good] && duplicated.openReport.skippedRecordCount == 0)
            #expect(duplicated.openReport.backupURL == nil)

            var object = try #require(
                JSONSerialization.jsonObject(with: ArchiveFileFormat.encode([good])) as? [String: Any])
            object["items"] = (object["items"] as? [Any] ?? []) + [["junk": true]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            _ = try ArchiveStore(fileURL: url)
            let second = try ArchiveStore(fileURL: url)
            #expect(second.openReport.skippedRecordCount == 0 && second.openReport.backupURL == nil)
            let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                $0.contains("repaired")
            }
            #expect(copies.count == 1)
        }
    }

    // MARK: Clock

    @Test func manualTimeSourceOnlyMovesWhenAdvanced() {
        let clock = ManualTimeSource(start)
        #expect(clock.now == start)
        clock.advance(by: 13 * hour)
        #expect(clock.now == start.addingTimeInterval(13 * hour))
        clock.set(start)
        #expect(clock.now == start)
    }
}
