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
    /// Profiles whose storage could not be set up, so each is reported once a run.
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
        guard let record = registry?.profile(for: id), !failedSetups.contains(record.id.rawValue.lowercased()) else {
            return nil
        }
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

    private func setupFailed(_ record: ProfileRecord, _ reason: String) {
        failedSetups.insert(record.id.rawValue.lowercased())
        Self.report("the profile \(record.id.rawValue) cannot be set up: \(reason)")
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("bow: \(message)\n".utf8))
    }
}
