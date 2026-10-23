import Foundation
import Testing

@testable import BowCore

@Suite struct ProfileRegistryTests {
    private func root(_ folder: URL) -> URL { folder.appendingPathComponent("Chromium", isDirectory: true) }

    private func open(_ folder: URL) throws -> ProfileRegistry {
        try ProfileRegistry(fileURL: folder.appendingPathComponent(ProfileRegistry.fileName), dataRoot: root(folder))
    }

    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: url.appendingPathComponent("Cookies"))
    }

    private let nobody = [SidebarProfileID]()

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
            let root = root(folder)
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
        #expect(ProfileRegistry.sanitizedID(from: String(repeating: "a", count: 90)).count == 48)
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
            let root = root(folder)
            let kept = root.appendingPathComponent("Profile-keep", isDirectory: true)
            let doomed = root.appendingPathComponent("Profile-work", isDirectory: true)
            let registry = try open(folder)
            let work = try registry.create(name: "Work")
            _ = try registry.create(name: "Keep")
            // The engine creates each folder after the profile exists.
            for url in [kept, doomed, root.appendingPathComponent("Default", isDirectory: true)] {
                try makeFolder(url)
            }
            try registry.markForDeletion(work.id, spaceProfiles: [SidebarProfileID.default])

            // Marked, but nothing is deleted while this launch's browsers may be open.
            #expect(registry.profile(for: work.id) == nil)
            #expect(registry.pendingDeletions == ["Profile-work"])
            #expect(FileManager.default.fileExists(atPath: doomed.path))

            let nextLaunch = try open(folder)
            #expect(nextLaunch.pendingDeletions == ["Profile-work"])
            let results = try nextLaunch.applyPendingDeletions(spaceProfiles: nobody)
            #expect(results == [.init(folderName: "Profile-work", outcome: .removed)])
            #expect(!FileManager.default.fileExists(atPath: doomed.path))
            #expect(FileManager.default.fileExists(atPath: kept.path))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Default").path))
            #expect(try open(folder).pendingDeletions.isEmpty)
        }
    }

    @Test func aFolderThatCannotBeRemovedStaysPendingForTheNextLaunch() throws {
        try withTemporaryFolder { folder in
            let root = root(folder)
            let registry = try open(folder)
            let created = try registry.create(name: "A")
            try makeFolder(root.appendingPathComponent("Profile-a"))
            try registry.markForDeletion(created.id, spaceProfiles: nobody)
            struct Busy: Error {}
            let results = try registry.applyPendingDeletions(spaceProfiles: nobody) { _ in throw Busy() }
            #expect(results.count == 1)
            guard case .failed = results[0].outcome else {
                Issue.record("expected a failure, got \(results[0])")
                return
            }
            #expect(try open(folder).pendingDeletions == ["Profile-a"])
            #expect(try open(folder).applyPendingDeletions(spaceProfiles: nobody).map(\.outcome) == [.removed])
        }
    }

    @Test func aMissingFolderClearsItsEntry() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            try registry.markForDeletion(try registry.create(name: "A").id, spaceProfiles: [SidebarProfileID]())
            let results = try registry.applyPendingDeletions(spaceProfiles: nobody)
            #expect(results.map(\.outcome) == [.alreadyGone])
            #expect(registry.pendingDeletions.isEmpty)
        }
    }

    @Test func aDeletedProfilesIDIsNeverGivenToANewProfile() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let first = try registry.create(name: "Work")
            let guest = try registry.create(name: "Guest", isPersistent: false)
            try registry.markForDeletion(first.id, spaceProfiles: nobody)
            try registry.markForDeletion(guest.id, spaceProfiles: nobody)
            #expect(try registry.create(name: "Work").id == "work-2")
            #expect(try registry.create(name: "Guest").id == "guest-2")
            // Even after the folder is gone and after a relaunch.
            try registry.applyPendingDeletions(spaceProfiles: nobody)
            #expect(registry.pendingDeletions.isEmpty)
            let later = try open(folder)
            #expect(later.retiredIDs == ["work", "guest"])
            #expect(try later.create(name: "Work").id == "work-3")
            #expect(try later.create(name: "Guest").id == "guest-3")
        }
    }

    @Test func profileFoldersAlreadyOnDiskAreTakenEvenWhenTheFileForgotThem() throws {
        try withTemporaryFolder { folder in
            try makeFolder(root(folder).appendingPathComponent("Profile-work"))
            try makeFolder(root(folder).appendingPathComponent("profile-Home"))
            let registry = try open(folder)
            #expect(try registry.create(name: "Work").id == "work-2")
            #expect(try registry.create(name: "Home").id == "home-2")
            #expect(try registry.create(name: "Other").id == "other")
        }
    }

    @Test func anUnreadableFileLosesPendingDeletionsButNotTheirIDs() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            try makeFolder(root(folder).appendingPathComponent("Profile-work"))
            try registry.markForDeletion(try registry.create(name: "Work").id, spaceProfiles: nobody)
            try Data("garbage".utf8).write(to: registry.fileURL)
            let reopened = try open(folder)
            #expect(reopened.pendingDeletions.isEmpty)
            #expect(try reopened.create(name: "Work").id == "work-2")
            #expect(FileManager.default.fileExists(atPath: root(folder).appendingPathComponent("Profile-work").path))
        }
    }

    @Test func aPendingFolderIsKeptWhenASpaceShowsItAgain() throws {
        try withTemporaryFolder { folder in
            // Undo an import, delete its profile, redo the import: the Space shows the profile again.
            let id = ArcImportProfileTarget.profileID(forArcProfile: "Profile 1")
            let registry = try open(folder)
            try registry.adopt(id: id, name: "Profile 1")
            let doomed = root(folder).appendingPathComponent("Profile-\(id.rawValue)")
            try makeFolder(doomed)
            try registry.markForDeletion(id, spaceProfiles: nobody)
            #expect(registry.pendingDeletions == ["Profile-\(id.rawValue)"])

            let nextLaunch = try open(folder)
            let shown = [SidebarProfileID(id.rawValue.uppercased())]
            let results = try nextLaunch.applyPendingDeletions(spaceProfiles: shown)
            #expect(results.map(\.outcome) == [.keptInUse])
            #expect(FileManager.default.fileExists(atPath: doomed.path))
            #expect(nextLaunch.pendingDeletions == ["Profile-\(id.rawValue)"])
            // The app then registers the profile again, and the folder is its storage.
            #expect(try nextLaunch.adopt(id: id, name: "Profile 1").id == id)
            #expect(nextLaunch.pendingDeletions.isEmpty)
            #expect(try open(folder).profile(for: id) != nil)
        }
    }

    @Test func adoptingARetiredIDClearsItsPendingDeletion() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let work = try registry.create(name: "Work")
            try registry.markForDeletion(work.id, spaceProfiles: nobody)
            try registry.adopt(id: "work", name: "Work")
            #expect(registry.pendingDeletions.isEmpty)
            #expect(registry.retiredIDs.isEmpty)
        }
    }

    // MARK: Adopting chosen IDs

    @Test func arcImportProfileIDsRoundTripThroughTheRegistryIncludingLongNames() throws {
        try withTemporaryFolder { folder in
            let names = [
                "Default", "Profile 1", "Profile 12", "Work", "WORK", "work",
                String(repeating: "Very Long Arc Profile Name ", count: 5), String(repeating: "a", count: 200),
                "名前", "A/B..C", " ", "x",
            ]
            let ids = names.map { ArcImportProfileTarget.profileID(forArcProfile: $0) }
            #expect(ids.contains { $0.rawValue.count == 47 })
            let registry = try open(folder)
            for pass in 1...2 {
                for (name, id) in zip(names, ids) {
                    let record = try registry.adopt(
                        id: id, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Arc" : name)
                    #expect(record.id == id, "pass \(pass): \(name)")
                    #expect(registry.ref(for: id) == .persistent(ProfileID(id.rawValue)))
                }
            }
            #expect(registry.profiles.count == Set(ids).count + 1)
            #expect(try open(folder).profiles.map(\.id) == registry.profiles.map(\.id))
        }
    }

    @Test func adoptValidatesAndRefusesCaseInsensitiveClashes() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            #expect(throws: ProfileRegistryError.invalidID("a b")) { try registry.adopt(id: "a b", name: "X") }
            #expect(throws: ProfileRegistryError.invalidID("..")) { try registry.adopt(id: "..", name: "X") }
            let tooLong = SidebarProfileID(String(repeating: "a", count: 49))
            #expect(throws: ProfileRegistryError.invalidID(tooLong.rawValue)) {
                try registry.adopt(id: tooLong, name: "X")
            }
            #expect(throws: ProfileRegistryError.emptyName) { try registry.adopt(id: "ok", name: " ") }
            let first = try registry.adopt(id: "Arc-Work", name: "Work", isPersistent: true)
            #expect(try registry.adopt(id: "Arc-Work", name: "Other name", isPersistent: false) == first)
            #expect(throws: ProfileRegistryError.idClash("Arc-Work")) { try registry.adopt(id: "arc-work", name: "X") }
            #expect(throws: ProfileRegistryError.idClash("default")) { try registry.adopt(id: "DEFAULT", name: "X") }
            #expect(try registry.adopt(id: .default, name: "Ignored").id == .default)
            #expect(registry.profiles.count == 2)
        }
    }

    @Test func matchingIgnoresCase() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let work = try registry.create(name: "Work")
            #expect(registry.profile(for: "WORK") == work)
            #expect(throws: ProfileRegistryError.profileInUse("Work")) {
                try registry.markForDeletion("Work", spaceProfiles: [SidebarProfileID("WORK")])
            }
            try registry.markForDeletion("WoRk", spaceProfiles: nobody)
            #expect(registry.profile(for: "work") == nil)
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
            let fileManager = FileManager.default
            let root = root(folder)
            try makeFolder(root.appendingPathComponent("Default"))
            try makeFolder(root.appendingPathComponent("Profile-live"))
            try makeFolder(root.appendingPathComponent("Profile-ok"))
            let beside = folder.appendingPathComponent("escape", isDirectory: true)
            try makeFolder(beside)
            let outside = folder.appendingPathComponent("Outside", isDirectory: true)
            try makeFolder(outside)
            try fileManager.createSymbolicLink(
                at: root.appendingPathComponent("Profile-link"), withDestinationURL: outside)
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            let json = """
                {"version":1,"profiles":[{"id":"live","name":"Live","isPersistent":true}],
                 "pendingDeletions":["../escape","Default","Profile-","Profile-a/b","Profile-ok","profile-OK","Profile-live",
                                     "Profile-link",7]}
                """
            try Data(json.utf8).write(to: url)
            let registry = try ProfileRegistry(fileURL: url, dataRoot: root)
            #expect(registry.pendingDeletions == ["Profile-ok", "Profile-link"])
            try registry.applyPendingDeletions(spaceProfiles: nobody)
            #expect(fileManager.fileExists(atPath: root.appendingPathComponent("Default/Cookies").path))
            #expect(fileManager.fileExists(atPath: root.appendingPathComponent("Profile-live/Cookies").path))
            #expect(fileManager.fileExists(atPath: beside.appendingPathComponent("Cookies").path))
            #expect(!fileManager.fileExists(atPath: root.appendingPathComponent("Profile-ok").path))
            // The link itself goes; what it pointed at stays.
            #expect(
                (try? fileManager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Profile-link").path))
                    == nil)
            #expect(fileManager.fileExists(atPath: outside.appendingPathComponent("Cookies").path))
        }
    }

    @Test func theFolderNameGuardStopsEntriesThatBypassReading() throws {
        // Reading already cleans the list; this checks the guard in applyPendingDeletions on its own by
        // writing the entries into a registry that was opened before the file changed.
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            try makeFolder(root(folder).appendingPathComponent("Profile-ok"))
            let beside = folder.appendingPathComponent("escape", isDirectory: true)
            try makeFolder(beside)
            registry.pendingDeletions = ["../escape", "Default", "Profile-ok"]
            var removed: [String] = []
            try registry.applyPendingDeletions(spaceProfiles: nobody) { removed.append($0.lastPathComponent) }
            #expect(removed == ["Profile-ok"])
            #expect(FileManager.default.fileExists(atPath: beside.appendingPathComponent("Cookies").path))
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
            let registry = try ProfileRegistry(fileURL: url, dataRoot: root(folder))
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
            let registry = try ProfileRegistry(fileURL: url, dataRoot: root(folder))
            guard case .freshAfterSettingAside(let aside, _) = registry.openReport.origin else {
                Issue.record("expected the file to be set aside")
                return
            }
            #expect(try String(contentsOf: aside, encoding: .utf8) == "not json")
            try registry.save()
            #expect(try open(folder).profiles.map(\.id) == [.default])
        }
    }

    @Test func aFileFromANewerBuildIsRefusedAndLeftWhereItIs() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            let newer = Data(#"{"version":99,"profiles":[]}"#.utf8)
            try newer.write(to: url)
            let refused = ProfileRegistryError.fileFromNewerBuild(
                version: 99, readable: ProfileFileFormat.currentVersion)
            #expect(throws: refused) { try ProfileRegistry(fileURL: url, dataRoot: root(folder)) }
            #expect(try Data(contentsOf: url) == newer)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [url.lastPathComponent])
        }
    }

    @Test func aFileThatCannotBeReadIsRefusedAndNotSetAside() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            let contents = Data(#"{"version":99,"profiles":[]}"#.utf8)
            try contents.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            #expect {
                _ = try ProfileRegistry(fileURL: url, dataRoot: root(folder))
            } throws: { error in
                guard case .unreadableFileNotSetAside(let reason) = error as? ProfileRegistryError else { return false }
                return reason.hasPrefix("reading failed")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [url.lastPathComponent])
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            #expect(try Data(contentsOf: url) == contents)
        }
    }

    @Test func anOlderFileMigratesWhenTheRegistryOpens() throws {
        try withTemporaryFolder { folder in
            let url = folder.appendingPathComponent(ProfileRegistry.fileName)
            try Data(#"{"version":0}"#.utf8).write(to: url)
            let migrate = ProfileFileFormat.Migration(from: 0) { object in
                object["profiles"] = [["id": "old", "name": "Old", "isPersistent": true]]
            }
            // The store reads up to ProfileFileFormat.currentVersion, so a version 0 file needs the migration to 1.
            let registry = try ProfileRegistry(
                fileURL: url, dataRoot: root(folder), migrations: [migrate], writer: AtomicFileWriter())
            #expect(registry.openReport.origin == .loaded)
            #expect(registry.openReport.migratedFrom == 0)
            #expect(registry.profile(for: "old")?.name == "Old")
        }
    }

    @Test func unknownProfileIDsAreReportedOnceInOrder() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            #expect(registry.unknownProfileIDs(in: [.default, "b", "a", "b", "B"]) == ["b", "a"])
            #expect(TabMoveKind.between("Work", "work") == .keepsLivePage)
        }
    }

    @Test func aFailedSaveKeepsTheChangeAndReportsIt() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
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
