import Foundation
import Testing

@testable import BowCore

@Suite struct ProfileRegistryTests {
    private func open(_ folder: URL) throws -> ProfileRegistry {
        try ProfileRegistry(fileURL: folder.appendingPathComponent(ProfileRegistry.fileName))
    }

    @Test func freshRegistryHasOnlyThePersistentDefault() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            #expect(registry.profiles.map(\.id) == [.default])
            #expect(registry.ref(for: .default) == .persistent(.default))
            #expect(registry.folderName(for: .default) == "Default")
            #expect(registry.openReport.origin == .freshBecauseMissing)
            #expect(registry.profile(for: "nope") == nil)
        }
    }

    @Test func createdProfilesSurviveReopeningWithRenamesAndEphemeralFlag() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let work = try registry.create(name: "Work")
            let guest = try registry.create(name: "Guest", isPersistent: false)
            try registry.rename(work.id, to: "  Job  ")
            let reopened = try open(folder)
            #expect(reopened.profiles.map(\.id.rawValue) == ["default", "work", "guest"])
            #expect(reopened.profile(for: work.id)?.name == "Job")
            #expect(reopened.ref(for: work.id) == .persistent("work"))
            #expect(reopened.ref(for: guest.id) == .ephemeral("guest"))
            #expect(reopened.folderName(for: guest.id) == nil)
            #expect(reopened.folderName(for: work.id) == "Profile-work")
            #expect(reopened.openReport.origin == .loaded)
            #expect(!reopened.hasUnsavedChanges)
        }
    }

    @Test func cachePathIsExactlyOneLevelUnderTheRoot() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let root = folder.appendingPathComponent("Chromium", isDirectory: true)
            let work = try registry.create(name: "Work")
            #expect(work.cachePath(inRoot: root) == root.appendingPathComponent("Profile-work", isDirectory: true))
            #expect(registry.profile(for: .default)?.cachePath(inRoot: root)?.lastPathComponent == "Default")
            #expect(try registry.create(name: "Temp", isPersistent: false).cachePath(inRoot: root) == nil)
        }
    }

    @Test func idsUseOnlyAllowedCharactersAndNeverCollideIgnoringCase() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let ids = try [
                registry.create(name: "Work"), registry.create(name: "WORK"), registry.create(name: "work"),
                registry.create(name: "Default"), registry.create(name: "  Ünï / cødé ?  "),
                registry.create(name: "...", preferredID: "../x"), registry.create(name: "名前"),
            ].map(\.id.rawValue)
            #expect(ids == ["work", "work-2", "work-3", "default-2", "n-c-d", "x", "profile"])
            #expect(ids.allSatisfy(ProfileRegistry.isValidID))
            let lowered = (registry.profiles.map(\.id.rawValue)).map { $0.lowercased() }
            #expect(Set(lowered).count == lowered.count)
        }
    }

    @Test func sanitizingFitsArcProfileFolderNames() {
        #expect(ProfileRegistry.sanitizedID(from: "Profile 1") == "profile-1")
        #expect(ProfileRegistry.sanitizedID(from: "Profile 12") == "profile-12")
        #expect(ProfileRegistry.sanitizedID(from: ".hidden") == "hidden")
        #expect(ProfileRegistry.sanitizedID(from: String(repeating: "a", count: 90)).count == 40)
        #expect(ProfileRegistry.sanitizedID(from: "") == "profile")
    }

    @Test func emptyNamesAreRefused() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            #expect(throws: ProfileRegistryError.emptyName) { try registry.create(name: " \n") }
            #expect(throws: ProfileRegistryError.emptyName) { try registry.rename(.default, to: "") }
            #expect(throws: ProfileRegistryError.profileNotFound("x")) { try registry.rename("x", to: "A") }
        }
    }

    @Test func manySpacesMayShareOneProfile() throws {
        var graph = SidebarGraph.sample()
        try graph.apply(.insertSpace("two", title: "Two", index: nil, profileID: .default))
        try graph.apply(.insertSpace("three", title: "Three", index: nil, profileID: "work"))
        #expect(graph.spaces.map(\.profileID.rawValue) == ["default", "default", "work"])
        #expect(graph.tabMoveKind(from: "home", to: "two") == .keepsLivePage)
    }

    @Test func movingBetweenSpacesOnTheSameProfileKeepsTheLivePage() throws {
        var graph = SidebarGraph.sample()
        try graph.apply(.insertSpace("two", title: "Two", index: nil, profileID: "work"))
        try graph.apply(.insertSpace("three", title: "Three", index: nil, profileID: "work"))
        #expect(graph.tabMoveKind(from: "two", to: "three") == .keepsLivePage)
        #expect(graph.tabMoveKind(from: "two", to: "two") == .keepsLivePage)
        #expect(graph.tabMoveKind(from: "home", to: "two") == .needsReload(from: .default, to: "work"))
        #expect(graph.tabMoveKind(from: "two", to: "home") == .needsReload(from: "work", to: .default))
        #expect(graph.tabMoveKind(from: "home", to: "missing") == nil)
        #expect(graph.tabMoveKind(from: "missing", to: "home") == nil)
    }

    // MARK: Deletion

    @Test func deletingAProfileRemovesItsFolderOnlyAtTheNextLaunch() throws {
        try withTemporaryFolder { folder in
            let root = folder.appendingPathComponent("Chromium", isDirectory: true)
            let kept = root.appendingPathComponent("Profile-keep", isDirectory: true)
            let doomed = root.appendingPathComponent("Profile-work", isDirectory: true)
            for url in [kept, doomed, root.appendingPathComponent("Default", isDirectory: true)] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("cookie".utf8).write(to: url.appendingPathComponent("Cookies"))
            }
            let registry = try open(folder)
            let work = try registry.create(name: "Work")
            _ = try registry.create(name: "Keep")
            try registry.markForDeletion(work.id, spaceProfiles: [SidebarProfileID.default])

            // Marked, but nothing is deleted while this launch's browsers may be open.
            #expect(registry.profile(for: work.id) == nil)
            #expect(registry.pendingDeletions == ["Profile-work"])
            #expect(FileManager.default.fileExists(atPath: doomed.path))

            let nextLaunch = try open(folder)
            #expect(nextLaunch.pendingDeletions == ["Profile-work"])
            let results = try nextLaunch.applyPendingDeletions(inRoot: root)
            #expect(results == [.init(folderName: "Profile-work", outcome: .removed)])
            #expect(!FileManager.default.fileExists(atPath: doomed.path))
            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Default").path))
            #expect(try open(folder).pendingDeletions.isEmpty)
        }
    }

    @Test func aFolderThatCannotBeRemovedStaysPendingForTheNextLaunch() throws {
        try withTemporaryFolder { folder in
            let root = folder.appendingPathComponent("Chromium", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Profile-a"), withIntermediateDirectories: true)
            let registry = try open(folder)
            try registry.markForDeletion(try registry.create(name: "A").id, spaceProfiles: [SidebarProfileID]())
            struct Busy: Error {}
            let results = try registry.applyPendingDeletions(inRoot: root) { _ in throw Busy() }
            #expect(results.count == 1)
            guard case .failed = results[0].outcome else {
                Issue.record("expected a failure, got \(results[0])")
                return
            }
            #expect(try open(folder).pendingDeletions == ["Profile-a"])
            #expect(try open(folder).applyPendingDeletions(inRoot: root).map(\.outcome) == [.removed])
        }
    }

    @Test func aMissingFolderClearsItsEntry() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            try registry.markForDeletion(try registry.create(name: "A").id, spaceProfiles: [SidebarProfileID]())
            let results = try registry.applyPendingDeletions(inRoot: folder.appendingPathComponent("Nowhere"))
            #expect(results.map(\.outcome) == [.alreadyGone])
            #expect(registry.pendingDeletions.isEmpty)
        }
    }

    @Test func aPendingFolderNameIsNotReusedUntilItIsDeleted() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let first = try registry.create(name: "Work")
            try registry.markForDeletion(first.id, spaceProfiles: [SidebarProfileID]())
            let second = try registry.create(name: "Work")
            #expect(second.id == "work-2")
            try registry.applyPendingDeletions(inRoot: folder)
            #expect(try registry.create(name: "Work").id == "work")
        }
    }

    @Test func deletionRefusesTheDefaultAProfileInUseAndUnknownIDs() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let work = try registry.create(name: "Work")
            #expect(throws: ProfileRegistryError.cannotDeleteDefault) {
                try registry.markForDeletion(.default, spaceProfiles: [SidebarProfileID]())
            }
            #expect(throws: ProfileRegistryError.profileInUse(work.id)) {
                try registry.markForDeletion(work.id, spaceProfiles: [.default, work.id])
            }
            #expect(throws: ProfileRegistryError.profileNotFound("x")) {
                try registry.markForDeletion("x", spaceProfiles: [SidebarProfileID]())
            }
            #expect(registry.profile(for: work.id) != nil)
            #expect(registry.pendingDeletions.isEmpty)
        }
    }

    @Test func deletingAnEphemeralProfileLeavesNothingToDelete() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let guest = try registry.create(name: "Guest", isPersistent: false)
            try registry.markForDeletion(guest.id, spaceProfiles: [SidebarProfileID]())
            #expect(registry.pendingDeletions.isEmpty)
            #expect(registry.profiles.map(\.id) == [.default])
        }
    }

    @Test func hostileDeletionEntriesNeverReachTheFileSystem() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            let json = """
                {"version":1,"profiles":[{"id":"live","name":"Live","isPersistent":true}],
                 "pendingDeletions":["../escape","Default","Profile-","Profile-a/b","Profile-ok","profile-OK","Profile-live",7]}
                """
            try Data(json.utf8).write(to: url)
            let registry = try ProfileRegistry(fileURL: url)
            #expect(registry.pendingDeletions == ["Profile-ok"])
            var removed: [String] = []
            try registry.applyPendingDeletions(inRoot: folder) { removed.append($0.lastPathComponent) }
            #expect(removed.isEmpty)  // the folder does not exist
        }
    }

    // MARK: Reading the file

    @Test func theDefaultProfileIsRestoredAndBadEntriesAreDropped() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            let json = """
                {"version":1,"profiles":[
                  {"id":"a b","name":"Bad ID","isPersistent":true},
                  {"id":"Work","name":"Work","isPersistent":true},
                  {"id":"WORK","name":"Clash","isPersistent":true},
                  {"id":"DEFAULT","name":"Clash with default","isPersistent":true},
                  {"id":"empty","name":"  ","isPersistent":true},
                  {"id":5},
                  {"id":"temp","name":"Temp","isPersistent":false}]}
                """
            try Data(json.utf8).write(to: url)
            let registry = try ProfileRegistry(fileURL: url)
            #expect(registry.profiles.map(\.id.rawValue) == ["default", "Work", "temp"])
            #expect(registry.profile(for: .default)?.isPersistent == true)
            #expect(registry.openReport.droppedEntryCount == 5)
            #expect(registry.hasUnsavedChanges)
        }
    }

    @Test func anUnreadableFileIsSetAsideNotOverwritten() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            try Data("not json".utf8).write(to: url)
            let registry = try ProfileRegistry(fileURL: url)
            guard case .freshAfterSettingAside(let aside, _) = registry.openReport.origin else {
                Issue.record("expected the file to be set aside")
                return
            }
            #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
            try registry.save()
            #expect(try open(folder).profiles.map(\.id) == [.default])
        }
    }

    @Test func aNewerFileIsSetAsideAndAnOlderOneMigrates() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            try Data(#"{"version":99,"profiles":[]}"#.utf8).write(to: url)
            let registry = try ProfileRegistry(fileURL: url)
            guard case .freshAfterSettingAside(_, let reason) = registry.openReport.origin else {
                Issue.record("expected the file to be set aside")
                return
            }
            #expect(reason.contains("newer"))
        }
        let migrate = ProfileFileFormat.Migration(from: 0) { object in
            object["profiles"] = [["id": "old", "name": "Old", "isPersistent": true]]
        }
        let data = Data(#"{"version":0}"#.utf8)
        let state = try ProfileFileFormat.decode(data, currentVersion: 1, migrations: [migrate])
        #expect(state.profiles.map(\.id.rawValue) == ["old"])
        #expect(state.migratedFrom == 0)
    }

    @Test func unknownProfileIDsAreReportedOnceInOrder() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            #expect(registry.unknownProfileIDs(in: [.default, "b", "a", "b"]) == ["b", "a"])
        }
    }

    @Test func aFailedSaveKeepsTheChangeAndReportsIt() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
            #expect(throws: ProfileRegistryError.self) { try registry.create(name: "Work") }
            #expect(registry.profile(for: "work") != nil)
            #expect(registry.hasUnsavedChanges)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try registry.save()
            #expect(try open(folder).profile(for: "work") != nil)
        }
    }
}
