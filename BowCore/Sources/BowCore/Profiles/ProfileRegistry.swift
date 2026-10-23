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

    public var description: String {
        switch self {
        case .profileNotFound(let id): return "no profile \(id)"
        case .emptyName: return "a profile needs a name"
        case .cannotDeleteDefault: return "the default profile cannot be deleted"
        case .profileInUse(let id): return "profile \(id) is still shown by a Space"
        case .saveFailed(let reason): return "saving the profiles failed: \(reason)"
        case .unreadableFileNotSetAside(let reason):
            return "the unreadable profiles file could not be set aside: \(reason)"
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
    }

    /// How one pending deletion went.
    public struct DeletionResult: Equatable, Sendable {
        public enum Outcome: Equatable, Sendable {
            case removed
            /// The folder was already gone; the entry is cleared.
            case alreadyGone
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
    /// by `applyPendingDeletions` at the next launch, and their IDs are not reused until then.
    public private(set) var pendingDeletions: [String]
    public private(set) var hasUnsavedChanges: Bool
    public let openReport: OpenReport

    private let writer: AtomicFileWriter
    /// IDs of temporary profiles deleted this session: the engine may still hold their memory, so they are not reused.
    private var retiredEphemeralIDs = Set<String>()

    /// Opens the registry stored at `fileURL`, creating nothing on disk until the first save. A missing file starts
    /// with the default profile. A file that cannot be read is moved aside under a new name and never overwritten.
    public convenience init(fileURL: URL) throws {
        try self.init(fileURL: fileURL, migrations: ProfileFileFormat.migrations, writer: AtomicFileWriter())
    }

    public static func fileURL(inApplicationSupportFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    init(fileURL: URL, migrations: [ProfileFileFormat.Migration], writer: AtomicFileWriter) throws {
        self.fileURL = fileURL
        self.writer = writer
        AtomicFileWriter.removeLeftovers(for: fileURL)

        var origin = Origin.loaded
        var state = ProfileFileFormat.State(profiles: [], pendingDeletions: [])
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            origin = .freshBecauseMissing
        } else {
            do {
                state = try ProfileFileFormat.decode(
                    try Data(contentsOf: fileURL), currentVersion: ProfileFileFormat.currentVersion,
                    migrations: migrations)
            } catch {
                origin = .freshAfterSettingAside(
                    setAsideURL: try Self.setAside(fileURL), reason: String(describing: error))
            }
        }

        let cleaned = Self.cleaned(state)
        profiles = cleaned.profiles
        pendingDeletions = cleaned.pendingDeletions
        hasUnsavedChanges = origin != .loaded || state.migratedFrom != nil || cleaned.changed
        openReport = OpenReport(
            origin: origin, migratedFrom: state.migratedFrom, droppedEntryCount: state.skippedCount + cleaned.dropped)
    }

    // MARK: Reading

    /// The profile with this ID, or nil. A Space whose profile is unknown (for example after the file was set
    /// aside) has no storage to show; the app picks a profile for it instead of guessing one.
    public func profile(for id: SidebarProfileID) -> ProfileRecord? { profiles.first { $0.id == id } }

    /// How to create the engine profile for `id`, or nil when the registry does not know it.
    public func ref(for id: SidebarProfileID) -> ProfileRef? { profile(for: id)?.ref }

    /// The folder name of a persistent profile, `Default` or `Profile-<id>`; nil for an ephemeral one or an unknown ID.
    public func folderName(for id: SidebarProfileID) -> String? { profile(for: id)?.folderName }

    /// The profile IDs in `ids` that the registry does not know, each once, in first-seen order.
    public func unknownProfileIDs(in ids: some Sequence<SidebarProfileID>) -> [SidebarProfileID] {
        var seen = Set<SidebarProfileID>()
        return ids.filter { profile(for: $0) == nil && seen.insert($0).inserted }
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
            isPersistent: isPersistent)
        profiles.append(record)
        try commit()
        return record
    }

    /// Changes the name the person sees; the ID and folder stay.
    public func rename(_ id: SidebarProfileID, to name: String) throws(ProfileRegistryError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw .profileNotFound(id) }
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
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw .profileNotFound(id) }
        guard id != .default else { throw .cannotDeleteDefault }
        guard !spaceProfiles.contains(id) else { throw .profileInUse(id) }
        let removed = profiles.remove(at: index)
        if let folder = removed.folderName {
            pendingDeletions.append(folder)
        } else {
            retiredEphemeralIDs.insert(removed.id.rawValue.lowercased())
        }
        try commit()
    }

    /// Deletes the folders of profiles marked for deletion under `root`, the folder that holds every profile
    /// folder. Call it at launch before the engine starts, when no browser can hold them open. A folder that cannot
    /// be removed stays on the list for the next launch. Saves when the list changed.
    @discardableResult
    public func applyPendingDeletions(
        inRoot root: URL,
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws(ProfileRegistryError) -> [DeletionResult] {
        var results: [DeletionResult] = []
        var remaining: [String] = []
        for folder in pendingDeletions {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            // Only names this registry could have written reach the file system, so a hand edited file cannot
            // point a deletion at anything else.
            guard Self.isPendingFolderName(folder), FileManager.default.fileExists(atPath: url.path) else {
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
                try ProfileFileFormat.encode(profiles: profiles, pendingDeletions: pendingDeletions), to: fileURL)
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

    /// Whether `text` can be a profile ID and folder name: not empty, not `.` or `..`, only ASCII letters, digits,
    /// `.`, `_` and `-`. The same rule as `ProfileID.isValid`.
    public static func isValidID(_ text: String) -> Bool { ProfileID(text).isValid }

    /// The ID `text` becomes: invalid characters turn into `-`, runs of `-` collapse, `-`, `.` and `_` are trimmed
    /// from both ends (a leading dot would hide the folder), letters go lower case, and at most 40 characters stay.
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
        if trimmed.count > 40 { trimmed = String(trimmed.prefix(40)).trimmingCharacters(in: trimSet) }
        return trimmed.isEmpty ? "profile" : trimmed
    }

    private func availableID(basedOn text: String) -> String {
        let base = Self.sanitizedID(from: text)
        var taken = Set(profiles.map { $0.id.rawValue.lowercased() })
        taken.insert(SidebarProfileID.default.rawValue.lowercased())
        for folder in pendingDeletions {
            taken.insert(String(folder.dropFirst(Self.folderPrefix.count)).lowercased())
        }
        taken.formUnion(retiredEphemeralIDs)
        var candidate = base
        var number = 2
        while taken.contains(candidate) {
            let suffix = "-\(number)"
            candidate = String(base.prefix(40 - suffix.count)) + suffix
            number += 1
        }
        return candidate
    }

    private static func isPendingFolderName(_ folder: String) -> Bool {
        folder.hasPrefix(folderPrefix) && isValidID(String(folder.dropFirst(folderPrefix.count)))
    }

    // MARK: Reading the file

    /// Makes what was read safe to use: the default profile is first and persistent, IDs are valid and unique
    /// ignoring case, and pending deletions are well formed, not used by a live profile, and listed once.
    private static func cleaned(
        _ state: ProfileFileFormat.State
    ) -> (profiles: [ProfileRecord], pendingDeletions: [String], dropped: Int, changed: Bool) {
        var dropped = 0
        var seen = Set<String>()
        var profiles: [ProfileRecord] = []
        let defaultKey = SidebarProfileID.default.rawValue.lowercased()
        let storedDefault = state.profiles.first { $0.id == .default }
        profiles.append(
            ProfileRecord(
                id: .default,
                name: storedDefault.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ?? defaultProfileName, isPersistent: true))
        seen.insert(defaultKey)
        for record in state.profiles where record.id != .default {
            let key = record.id.rawValue.lowercased()
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !isValidID(record.id.rawValue) || name.isEmpty || !seen.insert(key).inserted {
                dropped += 1
                continue
            }
            profiles.append(ProfileRecord(id: record.id, name: name, isPersistent: record.isPersistent))
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
        let changed = profiles != state.profiles || pending != state.pendingDeletions
        return (profiles, pending, dropped, changed)
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
