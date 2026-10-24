import Foundation
import Testing

@testable import BowCore

/// Each profile's storage UUID (`ProfileRecord.storeID`): given once, kept through saves, renames and reopening,
/// unique, and repaired when a file lacks one or shares one.
@Suite struct ProfileStoreIDTests {
    private func fileURL(_ folder: URL) -> URL { folder.appendingPathComponent(ProfileRegistry.fileName) }
    private func root(_ folder: URL) -> URL { folder.appendingPathComponent("Chromium", isDirectory: true) }

    private func open(_ folder: URL, ids: [UUID]? = nil) throws -> ProfileRegistry {
        var queue = ids ?? []
        return try ProfileRegistry(
            fileURL: fileURL(folder), dataRoot: root(folder), migrations: ProfileFileFormat.migrations,
            writer: AtomicFileWriter(), makeStoreID: { ids == nil ? UUID() : queue.removeFirst() })
    }

    private func uuid(_ last: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", last))!
    }

    private func write(_ json: String, in folder: URL) throws {
        try Data(json.utf8).write(to: fileURL(folder))
    }

    /// The file's profiles as written, by ID, with their `storeID` text.
    private func storedIDs(_ folder: URL) throws -> (version: Int, ids: [String: String]) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL(folder))) as? [String: Any]
        let profiles = object?["profiles"] as? [[String: Any]] ?? []
        var ids: [String: String] = [:]
        for profile in profiles {
            if let id = profile["id"] as? String { ids[id] = profile["storeID"] as? String }
        }
        return (object?["version"] as? Int ?? 0, ids)
    }

    @Test func theDefaultGetsAUUIDOnceAndTheAppMustSaveIt() throws {
        try withTemporaryFolder { folder in
            let fresh = try open(folder)
            let storeID = try #require(fresh.profile(for: .default)?.storeID)
            #expect(fresh.openReport.assignedStoreIDCount == 1)
            #expect(fresh.openReport.needsSaveAtOpen)
            #expect(fresh.ref(for: .default)?.storeID == storeID)
            try fresh.save()
            let reopened = try open(folder)
            #expect(reopened.profile(for: .default)?.storeID == storeID)
            #expect(reopened.openReport.assignedStoreIDCount == 0)
            #expect(!reopened.openReport.needsSaveAtOpen)
            #expect(!reopened.hasUnsavedChanges)
        }
    }

    @Test func aProfilesUUIDSurvivesRenamingSavingAndReopening() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            let work = try registry.create(name: "Work")
            let guest = try registry.create(name: "Guest", isPersistent: false)
            try registry.rename(work.id, to: "Job")
            #expect(try registry.adopt(id: work.id, name: "Again").storeID == work.storeID)
            let reopened = try open(folder)
            #expect(reopened.profile(for: "work")?.storeID == work.storeID)
            #expect(reopened.profile(for: "WORK")?.storeID == work.storeID)
            #expect(reopened.profile(for: "guest")?.storeID == guest.storeID)
            #expect(reopened.profile(withStoreID: work.storeID)?.id == "work")
            #expect(reopened.profile(withStoreID: UUID()) == nil)
            let stored = try storedIDs(folder)
            #expect(stored.version == 2)
            #expect(stored.ids["work"] == work.storeID.uuidString)
            #expect(stored.ids["default"] == registry.profile(for: .default)?.storeID.uuidString)
        }
    }

    @Test func uuidsAreUniqueEvenWhenTheGeneratorRepeatsOne() throws {
        try withTemporaryFolder { folder in
            // The default takes 1; Work's first candidate is 1 again, so it takes 2; Home's are 1 and 2, then 3.
            let registry = try open(folder, ids: [uuid(1), uuid(1), uuid(2), uuid(1), uuid(2), uuid(3)])
            let work = try registry.create(name: "Work")
            let home = try registry.adopt(id: "home", name: "Home")
            #expect(registry.profiles.map(\.storeID) == [uuid(1), uuid(2), uuid(3)])
            #expect(work.storeID == uuid(2))
            #expect(home.storeID == uuid(3))
        }
    }

    @Test func manyProfilesHaveDistinctUUIDs() throws {
        try withTemporaryFolder { folder in
            let registry = try open(folder)
            for number in 1...30 { try registry.create(name: "Profile \(number)") }
            #expect(Set(registry.profiles.map(\.storeID)).count == 31)
        }
    }

    @Test func aVersion1FileGivesEachProfileAUUIDOnce() throws {
        try withTemporaryFolder { folder in
            try write(
                """
                {"version":1,"profiles":[{"id":"default","name":"Default","isPersistent":true},
                  {"id":"work","name":"Work","isPersistent":true},{"id":"temp","name":"Temp","isPersistent":false}],
                 "pendingDeletions":[],"retiredIDs":[]}
                """, in: folder)
            let migrated = try open(folder)
            #expect(migrated.openReport.migratedFrom == 1)
            #expect(migrated.openReport.assignedStoreIDCount == 3)
            #expect(migrated.openReport.needsSaveAtOpen)
            #expect(migrated.profiles.map(\.id.rawValue) == ["default", "work", "temp"])
            #expect(Set(migrated.profiles.map(\.storeID)).count == 3)
            try migrated.save()
            let stored = try storedIDs(folder)
            #expect(stored.version == 2)
            #expect(stored.ids["work"] == migrated.profile(for: "work")?.storeID.uuidString)
            let reopened = try open(folder)
            #expect(reopened.profiles.map(\.storeID) == migrated.profiles.map(\.storeID))
            #expect(reopened.openReport.assignedStoreIDCount == 0)
            #expect(reopened.openReport.migratedFrom == nil)
        }
    }

    @Test func aHandEditedFileWithAMissingInvalidOrSharedUUIDIsRepaired() throws {
        try withTemporaryFolder { folder in
            let shared = uuid(1)
            let later = uuid(2)
            try write(
                """
                {"version":2,"profiles":[
                  {"id":"default","name":"Default","isPersistent":true,"storeID":"\(shared.uuidString)"},
                  {"id":"work","name":"Work","isPersistent":true,"storeID":"\(shared.uuidString.lowercased())"},
                  {"id":"home","name":"Home","isPersistent":true},
                  {"id":"temp","name":"Temp","isPersistent":false,"storeID":"not a uuid"},
                  {"id":"kept","name":"Kept","isPersistent":true,"storeID":"\(later.uuidString)"}],
                 "pendingDeletions":[],"retiredIDs":[]}
                """, in: folder)
            // Candidates that are already taken (by the first entry, or by a later entry's own UUID) are skipped.
            let repaired = try open(folder, ids: [shared, later, uuid(3), uuid(4), later, uuid(5)])
            #expect(repaired.profiles.map(\.id.rawValue) == ["default", "work", "home", "temp", "kept"])
            #expect(repaired.profiles.map(\.storeID) == [shared, uuid(3), uuid(4), uuid(5), later])
            #expect(repaired.openReport.assignedStoreIDCount == 3)
            #expect(repaired.openReport.droppedEntryCount == 0)
            #expect(repaired.openReport.needsSaveAtOpen)
            #expect(repaired.hasUnsavedChanges)
            try repaired.save()
            let reopened = try open(folder)
            #expect(reopened.profiles.map(\.storeID) == repaired.profiles.map(\.storeID))
            #expect(!reopened.openReport.needsSaveAtOpen)
        }
    }

    @Test func aDroppedEntryDoesNotHoldItsUUID() throws {
        try withTemporaryFolder { folder in
            let dropped = uuid(7)
            try write(
                """
                {"version":2,"profiles":[
                  {"id":"default","name":"Default","isPersistent":true,"storeID":"\(uuid(1).uuidString)"},
                  {"id":"Work","name":"Work","isPersistent":true},
                  {"id":"WORK","name":"Clash","isPersistent":true,"storeID":"\(dropped.uuidString)"}]}
                """, in: folder)
            let registry = try open(folder, ids: [dropped])
            #expect(registry.profiles.map(\.id.rawValue) == ["default", "Work"])
            #expect(registry.profile(for: "work")?.storeID == dropped)
            #expect(registry.openReport.droppedEntryCount == 1)
        }
    }
}
