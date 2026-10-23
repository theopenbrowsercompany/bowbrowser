import AppKit
import BowCore

/// The app's profiles (BowCore's `ProfileRegistry`), saved in `Profiles.json` beside the sidebar file in the data
/// directory, which is also the engine's root data folder, and the engine profile behind each of them.
///
/// The registry opens on first use. Each profile's engine storage is created lazily, the first time a window asks for
/// it (when one of its Spaces is first shown and its tab loads), after checking that its folder sits directly inside
/// the root and can be used, and is reused for every Space that shows the profile. A profile the engine already has
/// (the default one, or one an e2e run made) is used as it is.
@MainActor
final class ProfileRegistryStore: AppFeature {
    private let dataDirectory: URL
    private var opened: ProfileRegistry?
    /// Why the registry could not be opened, once it was tried; it is not tried again this run.
    private(set) var openFailure: String?
    /// Profiles whose storage could not be set up, so each failure is reported once a run.
    private var failedSetups: Set<String> = []

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    /// The registry, opened from the data directory on first use; nil when the file cannot be opened (it was
    /// written by a newer Bow, or cannot be read and could not be set aside), which is told once on standard error.
    var registry: ProfileRegistry? {
        if let opened { return opened }
        guard openFailure == nil else { return nil }
        do {
            let registry = try ProfileRegistry(
                fileURL: ProfileRegistry.fileURL(inApplicationSupportFolder: dataDirectory), dataRoot: dataDirectory)
            if case .freshAfterSettingAside(let url, let reason) = registry.openReport.origin {
                Self.report("the profiles file could not be read (\(reason)); it was moved to \(url.path)")
            }
            opened = registry
            return registry
        } catch {
            openFailure = "\(error)"
            Self.report("cannot open the profiles: \(error)")
            return nil
        }
    }

    /// The engine profile behind sidebar profile `id`: the one the engine already has, or else the registry's
    /// profile of that ID, created now. Nil when neither knows it, or its storage cannot be set up (its folder would
    /// not sit directly in the root, or is there but cannot be changed), so its tabs never open quietly in memory or
    /// in another profile.
    func engineProfile(for id: SidebarProfileID, engine: any BrowserEngine) -> (any EngineProfile)? {
        let engineID = SidebarStores.engineProfileID(of: id)
        if let existing = engine.profile(id: engineID) { return existing }
        guard let record = registry?.profile(for: id) else { return nil }
        // The Space may spell the ID in another letter case; the engine knows the profile by the registry's.
        if let existing = engine.profile(id: record.engineID) { return existing }
        let folder = record.cachePath(inRoot: dataDirectory)
        var isFolder: ObjCBool = false
        let exists = folder.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isFolder) } ?? false
        let writable = folder.map { isFolder.boolValue && FileManager.default.isWritableFile(atPath: $0.path) } ?? true
        let check = ProfileSetupCheck.check(record, root: dataDirectory, folderExists: exists, folderWritable: writable)
        guard check == .ready else {
            setupFailed(record, "\(check)")
            return nil
        }
        do {
            return try engine.createProfile(id: record.engineID, isPersistent: record.isPersistent)
        } catch {
            setupFailed(record, "\(error)")
            return nil
        }
    }

    /// Adds a persistent profile called `name` and saves the registry. Throws when the name is empty, the registry
    /// cannot be opened, or saving fails.
    func createProfile(named name: String) throws -> ProfileRecord {
        guard let registry else { throw ProfileRegistryError.unreadableFileNotSetAside(openFailure ?? "not opened") }
        return try registry.create(name: name)
    }

    /// The profiles the person may delete while the Spaces show `spaceProfiles`: every one but the default that no
    /// Space points at. Empty when the registry cannot be opened.
    func deletableProfiles(spaceProfiles: [SidebarProfileID]) -> [ProfileRecord] {
        registry?.deletableProfiles(spaceProfiles: spaceProfiles) ?? []
    }

    /// Takes profile `id` out of the list and marks its folder for deletion at the next launch; the folder stays now,
    /// since its engine storage may still be open. Throws when a Space still shows it, it is the default, or saving
    /// fails.
    func deleteProfile(_ id: SidebarProfileID, spaceProfiles: [SidebarProfileID]) throws {
        guard let registry else { throw ProfileRegistryError.unreadableFileNotSetAside(openFailure ?? "not opened") }
        try registry.markForDeletion(id, spaceProfiles: spaceProfiles)
    }

    /// The launch step: removes the folders of profiles deleted in an earlier run. The app calls it once its first
    /// window is open and before any other profile's storage is set up, so no browser can hold a deleted profile's
    /// folder (its storage is only ever created for a Space that shows it, and a profile is deleted only when none
    /// does). A folder whose profile a Space in `spaceProfiles` shows again stays; one that cannot be removed is tried
    /// again at the next launch. Returns what happened to each pending folder.
    @discardableResult
    func deleteMarkedFolders(spaceProfiles: [SidebarProfileID]) -> [ProfileRegistry.DeletionResult] {
        guard let registry else { return [] }
        do {
            let results = try registry.applyPendingDeletions(spaceProfiles: spaceProfiles)
            for result in results {
                if case .failed(let reason) = result.outcome {
                    Self.report("the deleted profile folder \(result.folderName) could not be removed: \(reason)")
                }
            }
            return results
        } catch {
            Self.report("the profiles file could not be saved after deleting folders: \(error)")
            return []
        }
    }

    private func setupFailed(_ record: ProfileRecord, _ reason: String) {
        // Checked again on every request, so a folder made writable works without a relaunch; told once.
        guard failedSetups.insert(record.id.rawValue.lowercased()).inserted else { return }
        Self.report("the profile \(record.id.rawValue) cannot be set up: \(reason)")
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("bow: \(message)\n".utf8))
    }
}
