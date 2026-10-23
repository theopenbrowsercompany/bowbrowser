import Foundation

/// The profiles file: versioned JSON holding the profile list and the folders waiting to be deleted.
///
/// The top level object has `version`, `profiles` (in order; each has `id`, `name`, `isPersistent`) and
/// `pendingDeletions` (folder names under the root data folder, such as `Profile-work`) and `retiredIDs` (lower case
/// IDs of every deleted profile, which are never given to a new one; absent in older files).
public enum ProfileFileFormat {
    /// The version this build writes. Raise it whenever the format changes, and add a migration from the old version.
    public static let currentVersion = 1

    /// Upgrades the raw JSON object of a file at version `from` to version `from + 1`. The store sets `version`.
    public struct Migration: Sendable {
        public var from: Int
        public var migrate: @Sendable (inout [String: Any]) throws -> Void

        public init(from: Int, migrate: @escaping @Sendable (inout [String: Any]) throws -> Void) {
            self.from = from
            self.migrate = migrate
        }
    }

    /// Every migration this build knows, one per older version. None yet.
    public static let migrations: [Migration] = []

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notJSONObject
        case missingVersion
        case newerVersion(Int)
        case noMigration(from: Int)
        case migrationFailed(from: Int, String)
        case invalidContents(String)

        public var description: String {
            switch self {
            case .notJSONObject: return "the file is not a JSON object"
            case .missingVersion: return "the file has no version"
            case .newerVersion(let version): return "the file is version \(version), newer than this build reads"
            case .noMigration(let version): return "no migration from version \(version)"
            case .migrationFailed(let version, let reason): return "migrating from version \(version) failed: \(reason)"
            case .invalidContents(let reason): return "the file contents are invalid: \(reason)"
            }
        }
    }

    struct State: Equatable {
        var profiles: [ProfileRecord]
        var pendingDeletions: [String]
        var retiredIDs: [String] = []
        /// How many profile or deletion entries could not be read and were left out.
        var skippedCount = 0
        var migratedFrom: Int?
    }

    private struct StoredProfile: Codable {
        var id: String
        var name: String
        var isPersistent: Bool
    }

    private struct Stored: Encodable {
        var version: Int
        var profiles: [StoredProfile]
        var pendingDeletions: [String]
        var retiredIDs: [String]
    }

    /// Reads entries one by one so a bad entry costs only itself.
    private struct ForgivingContents: Decodable {
        var profiles: [Forgiving<StoredProfile>]
        var pendingDeletions: [Forgiving<String>]
        var retiredIDs: [Forgiving<String>]

        private enum CodingKeys: String, CodingKey { case profiles, pendingDeletions, retiredIDs }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            profiles = try values.decode([Forgiving<StoredProfile>].self, forKey: .profiles)
            pendingDeletions = (try? values.decode([Forgiving<String>].self, forKey: .pendingDeletions)) ?? []
            retiredIDs = (try? values.decode([Forgiving<String>].self, forKey: .retiredIDs)) ?? []
        }
    }

    private struct Forgiving<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws { value = try? decoder.singleValueContainer().decode(Value.self) }
    }

    static func encode(profiles: [ProfileRecord], pendingDeletions: [String], retiredIDs: [String]) throws -> Data {
        let stored = Stored(
            version: currentVersion,
            profiles: profiles.map { StoredProfile(id: $0.id.rawValue, name: $0.name, isPersistent: $0.isPersistent) },
            pendingDeletions: pendingDeletions, retiredIDs: retiredIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(stored)
    }

    static func decode(
        _ data: Data,
        currentVersion: Int = currentVersion,
        migrations: [Migration] = migrations
    ) throws(ReadError) -> State {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .notJSONObject
        }
        guard let number = object["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let version = Int(exactly: number.doubleValue)
        else { throw .missingVersion }
        guard version <= currentVersion else { throw .newerVersion(version) }

        var upgraded = data
        if version < currentVersion {
            for from in version..<currentVersion {
                guard let migration = migrations.first(where: { $0.from == from }) else {
                    throw .noMigration(from: from)
                }
                do {
                    try migration.migrate(&object)
                } catch {
                    throw .migrationFailed(from: from, String(describing: error))
                }
                object["version"] = from + 1
            }
            do {
                upgraded = try JSONSerialization.data(withJSONObject: object)
            } catch {
                throw .migrationFailed(from: version, String(describing: error))
            }
        }

        let contents: ForgivingContents
        do {
            contents = try JSONDecoder().decode(ForgivingContents.self, from: upgraded)
        } catch {
            throw .invalidContents(String(describing: error))
        }
        let profiles = contents.profiles.compactMap(\.value).map {
            ProfileRecord(id: SidebarProfileID($0.id), name: $0.name, isPersistent: $0.isPersistent)
        }
        let pending = contents.pendingDeletions.compactMap(\.value)
        let retired = contents.retiredIDs.compactMap(\.value)
        return State(
            profiles: profiles,
            pendingDeletions: pending,
            retiredIDs: retired,
            skippedCount: contents.profiles.count - profiles.count + contents.pendingDeletions.count - pending.count
                + contents.retiredIDs.count - retired.count,
            migratedFrom: version < currentVersion ? version : nil)
    }
}
