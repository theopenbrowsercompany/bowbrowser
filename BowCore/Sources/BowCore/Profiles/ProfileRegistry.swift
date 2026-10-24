import Foundation

public enum ProfileRegistryError: Error, Equatable, CustomStringConvertible {
    case profileNotFound(SidebarProfileID)
    /// A profile name must have at least one character that is not whitespace.
    case emptyName
    /// The default profile always exists and cannot be deleted.
    case cannotDeleteDefault
    /// Spaces still show this profile; move or delete them first.
    case profileInUse(SidebarProfileID)
    /// The registry is kept in memory and marked unsaved, but writing the file failed.
    case saveFailed(String)
    case unreadableFileNotSetAside(String)
    /// The profiles file was written by a newer Bow, in format `version`, while this build reads up to `readable`.
    /// The registry refuses to open it and leaves it where it is, so the newer Bow still finds it.
    case fileFromNewerBuild(version: Int, readable: Int)
    /// The ID is empty, too long, or has characters other than `A-Z a-z 0-9 . _ -`.
    case invalidID(String)
    /// A different profile already has this ID, ignoring case.
    case idClash(String)

    public var description: String {
        switch self {
        case .profileNotFound(let id): return "no profile \(id)"
        case .emptyName: return "a profile needs a name"
        case .cannotDeleteDefault: return "the default profile cannot be deleted"
        case .profileInUse(let id): return "profile \(id) is still shown by a Space"
        case .saveFailed(let reason): return "saving the profiles failed: \(reason)"
        case .unreadableFileNotSetAside(let reason):
            return "the unreadable profiles file could not be set aside: \(reason)"
        case .fileFromNewerBuild(let version, let readable):
            return "the profiles file is format \(version), from a newer Bow; this build reads up to \(readable)"
        case .invalidID(let id): return "\"\(id)\" cannot be a profile ID"
        case .idClash(let id): return "another profile already has the ID \(id), ignoring case"
        }
    }
}

/// The list of profiles (storage areas for cookies, logins and history) and the folders waiting to be deleted.
///
/// A Space points at exactly one profile through `SidebarSpace.profileID`, and many Spaces may point at the same one.
/// The registry decides each profile's ID, which is also its engine profile ID and its folder name
/// (`Profile-<id>` one level under the root data folder), so the rules the engine enforces hold by construction:
/// only `[A-Za-z0-9._-]`, and no two IDs that differ only in case. The app creates each engine profile once, from
/// `ref(for:)`, and reuses it for every Space that shows the profile.
///
/// Beside its text ID each profile has one storage UUID (`ProfileRecord.storeID`), given once and unique among the
/// profiles, which names its engine storage and its extensions; the registry repairs a missing or shared one when it
/// reads the file, and `OpenReport.needsSaveAtOpen` asks the app to save then, so the UUID it gave is the one kept.
///
/// It is saved to its own `Profiles.json`; every change is written at once, since changes are rare.
public final class ProfileRegistry {
    /// The name of the profiles file inside the app's Application Support folder.
    public static let fileName = "Profiles.json"
    /// What precedes a profile's ID in its folder name.
    public static let folderPrefix = "Profile-"
    /// Written to the profile list when the default profile has to be created.
    public static let defaultProfileName = "Default"

    public enum Origin: Equatable, Sendable {
        case loaded
        case freshBecauseMissing
        /// The file could not be read; it was moved aside (never overwritten) and the registry starts with only
        /// the default profile.
        case freshAfterSettingAside(setAsideURL: URL, reason: String)
    }

    public struct OpenReport: Equatable, Sendable {
        public var origin: Origin
        public var migratedFrom: Int?
        /// Entries that were dropped while reading: unreadable, invalid ID, or an ID matching another in case.
        public var droppedEntryCount: Int
        /// Profiles given a new storage UUID while reading: the default of a fresh registry, every profile of a
        /// version 1 file, and any entry whose UUID was missing, not a UUID, or already another profile's.
        public var assignedStoreIDCount: Int

        /// Whether the app must save the registry as soon as it opens: a storage UUID given while reading is kept
        /// only once written, and otherwise the next launch would give the profile another one.
        public var needsSaveAtOpen: Bool { assignedStoreIDCount > 0 }
    }

    /// How one pending deletion went.
    public struct DeletionResult: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            case removed
            /// The folder was already gone; the entry is cleared.
            case alreadyGone
            /// A Space shows this profile again (for example a redone import): the folder stays and the entry stays
            /// until the profile is adopted again (which clears it) or no Space shows it any more.
            case keptInUse
            /// Removing failed; the entry stays and the next launch tries again.
            case failed(String)
        }
        public var folderName: String
        public var outcome: Outcome
    }

    public let fileURL: URL
    /// Every profile in the order they were created, the default first.
    public private(set) var profiles: [ProfileRecord]
    /// Folder names (`Profile-<id>`) of deleted persistent profiles whose data is still on disk. They are removed
    /// by `applyPendingDeletions` at the next launch.
    public internal(set) var pendingDeletions: [String]
    /// Lower case IDs of every deleted profile. History, site permissions and Favorites are keyed by profile ID
    /// outside this registry, so a retired ID is never given to a new profile (only `adopt` can bring one back).
    public private(set) var retiredIDs: [String]
    public private(set) var hasUnsavedChanges: Bool
    public let openReport: OpenReport

    /// The folder that holds every profile folder (`Default`, `Profile-<id>`). Folders already in it count as taken
    /// when choosing an ID, so a lost or unreadable file cannot hand a deleted login to a new profile.
    public let dataRoot: URL
    private let writer: AtomicFileWriter
    /// Makes candidate storage UUIDs; `newStoreID` skips any a profile already has.
    private let makeStoreID: () -> UUID

    /// Opens the registry stored at `fileURL`, creating nothing on disk until the first save. A missing file starts
    /// with the default profile. A file written by a newer Bow is left where it is and this throws
    /// `fileFromNewerBuild`. A file that cannot be read at all is left where it is and this throws
    /// `unreadableFileNotSetAside`. A file that was read but cannot be decoded or migrated is moved aside under a new
    /// name and never overwritten; if it cannot be moved, this also throws `unreadableFileNotSetAside`.
    public convenience init(fileURL: URL, dataRoot: URL) throws {
        try self.init(
            fileURL: fileURL, dataRoot: dataRoot, migrations: ProfileFileFormat.migrations, writer: AtomicFileWriter())
    }

    public static func fileURL(inApplicationSupportFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    init(
        fileURL: URL, dataRoot: URL, migrations: [ProfileFileFormat.Migration], writer: AtomicFileWriter,
        makeStoreID: @escaping () -> UUID = { UUID() }
    ) throws {
        self.fileURL = fileURL
        self.dataRoot = dataRoot
        self.writer = writer
        self.makeStoreID = makeStoreID

        var origin = Origin.loaded
        var state = ProfileFileFormat.State(profiles: [], pendingDeletions: [], retiredIDs: [])
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            origin = .freshBecauseMissing
        } else {
            // A file that cannot be read at all (permissions, a lock) is not known to be bad: refuse to start.
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw ProfileRegistryError.unreadableFileNotSetAside("reading failed: \(error)")
            }
            do {
                state = try ProfileFileFormat.decode(
                    data, currentVersion: ProfileFileFormat.currentVersion, migrations: migrations)
            } catch ProfileFileFormat.ReadError.newerVersion(let version) {
                // A newer Bow shares this folder; setting its file aside would cost it the profiles. Leave it alone.
                throw ProfileRegistryError.fileFromNewerBuild(
                    version: version, readable: ProfileFileFormat.currentVersion)
            } catch {
                origin = .freshAfterSettingAside(
                    setAsideURL: try Self.setAside(fileURL), reason: String(describing: error))
            }
        }

        // Only once the file is known to be this build's: a newer Bow's save in progress is not this build's to clear.
        AtomicFileWriter.removeLeftovers(for: fileURL)
        let cleaned = Self.cleaned(state, makeStoreID: makeStoreID)
        profiles = cleaned.profiles
        pendingDeletions = cleaned.pendingDeletions
        retiredIDs = cleaned.retiredIDs
        hasUnsavedChanges = origin != .loaded || state.migratedFrom != nil || cleaned.changed
        openReport = OpenReport(
            origin: origin, migratedFrom: state.migratedFrom, droppedEntryCount: state.skippedCount + cleaned.dropped,
            assignedStoreIDCount: cleaned.assigned)
    }

    // MARK: Reading

    /// The profile whose storage UUID is `storeID`, or nil.
    public func profile(withStoreID storeID: UUID) -> ProfileRecord? {
        profiles.first { $0.storeID == storeID }
    }

    /// The profile with this ID, or nil. A Space whose profile is unknown (for example after the file was set
    /// aside) has no storage to show; the app picks a profile for it instead of guessing one.
    /// IDs match ignoring case, as the engine matches folders.
    public func profile(for id: SidebarProfileID) -> ProfileRecord? {
        let key = id.rawValue.lowercased()
        return profiles.first { $0.id.rawValue.lowercased() == key }
    }

    /// How to create the engine profile for `id`, or nil when the registry does not know it.
    public func ref(for id: SidebarProfileID) -> ProfileRef? { profile(for: id)?.ref }

    /// The folder name of a persistent profile, `Default` or `Profile-<id>`; nil for an ephemeral one or an unknown ID.
    public func folderName(for id: SidebarProfileID) -> String? { profile(for: id)?.folderName }

    /// The profile IDs in `ids` that the registry does not know, each once, in first-seen order.
    public func unknownProfileIDs(in ids: some Sequence<SidebarProfileID>) -> [SidebarProfileID] {
        var seen = Set<String>()
        return ids.filter { profile(for: $0) == nil && seen.insert($0.rawValue.lowercased()).inserted }
    }

    /// The folder name of a persistent profile with this engine ID: `Default` or `Profile-<id>`.
    public static func folderName(for id: ProfileID) -> String {
        id == .default ? id.rawValue : folderPrefix + id.rawValue
    }

    // MARK: Changing

    /// Adds a profile and saves. `preferredID` (for example an Arc profile's folder name) or else the name is
    /// turned into an ID of allowed characters, lower case, that no profile or pending deletion already uses ignoring
    /// case; a number is added when it is taken. The ID never changes afterwards, even when the profile is renamed.
    @discardableResult
    public func create(
        name: String, preferredID: String? = nil, isPersistent: Bool = true
    ) throws(ProfileRegistryError) -> ProfileRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        let record = ProfileRecord(
            id: SidebarProfileID(availableID(basedOn: preferredID ?? trimmed)), name: trimmed,
            isPersistent: isPersistent, storeID: newStoreID())
        profiles.append(record)
        try commit()
        return record
    }

    /// Registers a profile under an ID that was already chosen elsewhere, such as the Arc import's, keeping it
    /// exactly. Idempotent: when a profile with exactly this ID exists it is returned unchanged. An ID that differs
    /// from an existing profile only in case is refused. A retired ID is allowed, because a Space shows it again
    /// (a redone import): it leaves the retired list and its folder is no longer waiting for deletion.
    @discardableResult
    public func adopt(
        id: SidebarProfileID, name: String, isPersistent: Bool = true
    ) throws(ProfileRegistryError) -> ProfileRecord {
        guard Self.isValidID(id.rawValue) else { throw .invalidID(id.rawValue) }
        if let existing = profile(for: id) {
            guard existing.id == id else { throw .idClash(existing.id.rawValue) }
            return existing
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        let key = id.rawValue.lowercased()
        retiredIDs.removeAll { $0 == key }
        pendingDeletions.removeAll { Self.id(ofFolder: $0) == key }
        // A profile registered again under a retired ID gets a new storage UUID, since the registry keeps no UUID of a
        // deleted profile (its folder, named by the ID, is what is kept today).
        let record = ProfileRecord(id: id, name: trimmed, isPersistent: isPersistent, storeID: newStoreID())
        profiles.append(record)
        try commit()
        return record
    }

    /// Changes the name the person sees; the ID and folder stay.
    public func rename(_ id: SidebarProfileID, to name: String) throws(ProfileRegistryError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard let found = profile(for: id), let index = profiles.firstIndex(where: { $0.id == found.id }) else {
            throw .profileNotFound(id)
        }
        guard profiles[index].name != trimmed else { return }
        profiles[index].name = trimmed
        try commit()
    }

    /// Takes the profile out of the list and, for a persistent one, records its folder to delete at the next launch.
    /// The folder stays on disk now because browsers using it may still be open. `spaceProfiles` are the profile
    /// IDs the Spaces show; deleting a profile one of them still shows is refused.
    public func markForDeletion(
        _ id: SidebarProfileID, spaceProfiles: some Sequence<SidebarProfileID>
    ) throws(ProfileRegistryError) {
        guard let found = profile(for: id), let index = profiles.firstIndex(where: { $0.id == found.id }) else {
            throw .profileNotFound(id)
        }
        guard found.id != .default else { throw .cannotDeleteDefault }
        let key = found.id.rawValue.lowercased()
        guard !spaceProfiles.contains(where: { $0.rawValue.lowercased() == key }) else { throw .profileInUse(id) }
        let removed = profiles.remove(at: index)
        if let folder = removed.folderName { pendingDeletions.append(folder) }
        if !retiredIDs.contains(key) { retiredIDs.append(key) }
        try commit()
    }

    /// Deletes the folders of profiles marked for deletion under `dataRoot`. Call it at launch before the engine
    /// starts, when no browser can hold them open. A folder that cannot be removed stays on the list for the next
    /// launch. A folder whose profile a Space shows again (`spaceProfiles`, ignoring case) is kept, with its entry,
    /// until `adopt` registers the profile again. Saves when the list changed.
    @discardableResult
    public func applyPendingDeletions(
        spaceProfiles: some Sequence<SidebarProfileID>,
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws(ProfileRegistryError) -> [DeletionResult] {
        var results: [DeletionResult] = []
        var remaining: [String] = []
        let shown = Set(spaceProfiles.map { $0.rawValue.lowercased() })
        for folder in pendingDeletions {
            // Only names this registry could have written reach the file system, so a hand edited file cannot
            // point a deletion at anything else.
            guard Self.isPendingFolderName(folder) else {
                results.append(DeletionResult(folderName: folder, outcome: .alreadyGone))
                continue
            }
            if shown.contains(Self.id(ofFolder: folder)) {
                results.append(DeletionResult(folderName: folder, outcome: .keptInUse))
                remaining.append(folder)
                continue
            }
            let url = dataRoot.appendingPathComponent(folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else {
                results.append(DeletionResult(folderName: folder, outcome: .alreadyGone))
                continue
            }
            do {
                try remove(url)
                results.append(DeletionResult(folderName: folder, outcome: .removed))
            } catch {
                results.append(DeletionResult(folderName: folder, outcome: .failed(String(describing: error))))
                remaining.append(folder)
            }
        }
        if remaining != pendingDeletions {
            pendingDeletions = remaining
            try commit()
        }
        return results
    }

    /// Writes the file if it is behind the registry.
    public func save() throws(ProfileRegistryError) {
        guard hasUnsavedChanges else { return }
        do {
            try writer.write(
                try ProfileFileFormat.encode(
                    profiles: profiles, pendingDeletions: pendingDeletions, retiredIDs: retiredIDs),
                to: fileURL)
        } catch {
            throw .saveFailed(String(describing: error))
        }
        hasUnsavedChanges = false
    }

    private func commit() throws(ProfileRegistryError) {
        hasUnsavedChanges = true
        try save()
    }

    // MARK: IDs

    /// The longest ID the registry holds: room for the Arc import's `arc-<32 characters>-<10 hex>` (47) plus one.
    public static let maxIDLength = 48

    /// Whether `text` can be a profile ID and folder name: not empty, at most `maxIDLength` characters, not `.` or
    /// `..`, only ASCII letters, digits, `.`, `_` and `-`. The engine's rule (`ProfileID.isValid`) plus the length.
    public static func isValidID(_ text: String) -> Bool { text.count <= maxIDLength && ProfileID(text).isValid }

    private static func id(ofFolder folder: String) -> String {
        String(folder.dropFirst(folderPrefix.count)).lowercased()
    }

    /// The ID `text` becomes: invalid characters turn into `-`, runs of `-` collapse, `-`, `.` and `_` are trimmed
    /// from both ends (a leading dot would hide the folder), letters go lower case, and at most `maxIDLength` (48) characters stay.
    /// `Profile 1` becomes `profile-1`. Text with nothing usable becomes `profile`.
    public static func sanitizedID(from text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            let character = Character(scalar)
            let allowed = scalar.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
            let next: Character = allowed ? character : "-"
            if next == "-", result.last == "-" { continue }
            result.append(next)
        }
        let trimSet = CharacterSet(charactersIn: "-._")
        var trimmed = result.trimmingCharacters(in: trimSet)
        if trimmed.count > maxIDLength { trimmed = String(trimmed.prefix(maxIDLength)).trimmingCharacters(in: trimSet) }
        return trimmed.isEmpty ? "profile" : trimmed
    }

    private func availableID(basedOn text: String) -> String {
        let base = Self.sanitizedID(from: text)
        var taken = Set(profiles.map { $0.id.rawValue.lowercased() })
        taken.insert(SidebarProfileID.default.rawValue.lowercased())
        for folder in pendingDeletions { taken.insert(Self.id(ofFolder: folder)) }
        taken.formUnion(retiredIDs)
        // Whatever profile folders exist count as taken, even when this file lost track of them.
        let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)) ?? []
        for name in onDisk where name.lowercased().hasPrefix(Self.folderPrefix.lowercased()) {
            taken.insert(Self.id(ofFolder: name))
        }
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            let suffix = "-\(number)"
            let room = Self.maxIDLength - suffix.count
            let cut = String(base.prefix(room)).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
            candidate = cut + suffix
            number += 1
        }
        return candidate
    }

    /// A storage UUID no profile has.
    private func newStoreID() -> UUID {
        Self.unusedStoreID(taken: Set(profiles.map(\.storeID)), makeStoreID: makeStoreID)
    }

    private static func unusedStoreID(taken: Set<UUID>, makeStoreID: () -> UUID) -> UUID {
        while true {
            let candidate = makeStoreID()
            if !taken.contains(candidate) { return candidate }
        }
    }

    private static func isPendingFolderName(_ folder: String) -> Bool {
        folder.hasPrefix(folderPrefix) && isValidID(String(folder.dropFirst(folderPrefix.count)))
    }

    // MARK: Reading the file

    /// Makes what was read safe to use: the default profile is first and persistent, IDs are valid and unique
    /// ignoring case, every kept profile has a storage UUID no other has (the first in file order keeps a shared one,
    /// and a missing or shared one is replaced by a new UUID from `makeStoreID`), and pending deletions are well
    /// formed, not used by a live profile, and listed once.
    private static func cleaned(
        _ state: ProfileFileFormat.State, makeStoreID: () -> UUID
    ) -> (
        profiles: [ProfileRecord], pendingDeletions: [String], retiredIDs: [String], dropped: Int, assigned: Int,
        changed: Bool
    ) {
        var dropped = 0
        var seen = Set<String>()
        var kept: [ProfileFileFormat.Entry] = []
        let defaultKey = SidebarProfileID.default.rawValue.lowercased()
        let storedDefault = state.profiles.first { $0.id == .default }
        kept.append(
            ProfileFileFormat.Entry(
                id: .default,
                name: storedDefault.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? defaultProfileName, isPersistent: true, storeID: storedDefault?.storeID))
        seen.insert(defaultKey)
        for record in state.profiles where record.id != .default {
            let key = record.id.rawValue.lowercased()
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isValidID(record.id.rawValue) || name.isEmpty || !seen.insert(key).inserted {
                dropped += 1
                continue
            }
            kept.append(
                ProfileFileFormat.Entry(
                    id: record.id, name: name, isPersistent: record.isPersistent, storeID: record.storeID))
        }
        // Every UUID read counts as taken, so a replacement never takes one a later entry still holds.
        var taken = Set(kept.compactMap(\.storeID))
        var owned = Set<UUID>()
        var assigned = 0
        var profiles: [ProfileRecord] = []
        for entry in kept {
            var storeID: UUID
            if let read = entry.storeID, owned.insert(read).inserted {
                storeID = read
            } else {
                storeID = unusedStoreID(taken: taken, makeStoreID: makeStoreID)
                taken.insert(storeID)
                owned.insert(storeID)
                assigned += 1
            }
            profiles.append(
                ProfileRecord(id: entry.id, name: entry.name, isPersistent: entry.isPersistent, storeID: storeID))
        }
        if let stored = storedDefault, stored.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profiles[0].name = defaultProfileName
        }
        let liveFolders = Set(profiles.compactMap { $0.folderName?.lowercased() })
        var pendingSeen = Set<String>()
        var pending: [String] = []
        for folder in state.pendingDeletions {
            if isPendingFolderName(folder), !liveFolders.contains(folder.lowercased()),
                pendingSeen.insert(folder.lowercased()).inserted
            {
                pending.append(folder)
            } else {
                dropped += 1
            }
        }
        var retiredSeen = Set<String>()
        var retired: [String] = []
        for id in state.retiredIDs {
            if isValidID(id), retiredSeen.insert(id.lowercased()).inserted {
                retired.append(id.lowercased())
            } else {
                dropped += 1
            }
        }
        // A deleted profile's folder is retired too, whatever the retired list says.
        for folder in pending {
            let id = Self.id(ofFolder: folder)
            if retiredSeen.insert(id).inserted { retired.append(id) }
        }
        let changed =
            profiles.map(ProfileFileFormat.Entry.init) != state.profiles || pending != state.pendingDeletions
            || retired != state.retiredIDs
        return (profiles, pending, retired, dropped, assigned, changed)
    }

    // MARK: File handling

    /// Moves an unreadable file to `Profiles.unreadable-<time>.json` beside it, never replacing an earlier one.
    private static func setAside(_ url: URL) throws(ProfileRegistryError) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        let stamp = formatter.string(from: Date())
        for attempt in 0..<1000 {
            let suffix = attempt == 0 ? stamp : "\(stamp)-\(attempt)"
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base).unreadable-\(suffix).\(url.pathExtension)")
            if FileManager.default.fileExists(atPath: candidate.path) { continue }
            do {
                try FileManager.default.moveItem(at: url, to: candidate)
            } catch {
                throw .unreadableFileNotSetAside(String(describing: error))
            }
            return candidate
        }
        throw .unreadableFileNotSetAside("no free name beside \(url.lastPathComponent)")
    }
}
