import Foundation

/// The archive file: versioned JSON, kept apart from the sidebar file.
///
/// The top level object has `version` and `items`, the archived entries newest first. Each entry has `item` (the full
/// sidebar item), `descendants`, `archivedAt` (seconds since 1970), `reason` and `source` (`spaceID`, `parentID`,
/// `index`).
public enum ArchiveFileFormat {
    /// The version this build writes. Raise it whenever the format changes, and add a migration from the old version.
    public static let currentVersion = 1

    /// Every migration this build knows, one per older version. Version 1 is the first format, so none exist yet.
    public static let migrations: [SidebarFileFormat.Migration] = []

    public typealias ReadError = SidebarFileFormat.ReadError

    public struct Decoded: Sendable {
        public var entries: [ArchivedEntry]
        /// The version the file was migrated from, or nil when it was already current.
        public var migratedFrom: Int?
        /// How many entries could not be read and were left out.
        public var skippedRecordCount: Int
    }

    private struct Contents: Encodable {
        var version: Int
        var items: [ArchivedEntry]
    }

    private struct ForgivingContents: Decodable {
        var items: [Forgiving]
    }

    private struct Forgiving: Decodable {
        var value: ArchivedEntry?
        init(from decoder: any Decoder) throws {
            value = try? decoder.singleValueContainer().decode(ArchivedEntry.self)
        }
    }

    public static func encode(_ entries: [ArchivedEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(Contents(version: currentVersion, items: entries))
    }

    public static func decode(
        _ data: Data,
        currentVersion: Int = currentVersion,
        migrations: [SidebarFileFormat.Migration] = migrations
    ) throws(ReadError) -> Decoded {
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            contents = try decoder.decode(ForgivingContents.self, from: upgraded)
        } catch {
            throw .invalidContents(String(describing: error))
        }
        var seen: Set<SidebarItemID> = []
        // One entry per item: a repeated ID keeps its first record, the newest.
        let entries = contents.items.compactMap(\.value).filter { seen.insert($0.id).inserted }
        return Decoded(
            entries: entries,
            migratedFrom: version < currentVersion ? version : nil,
            skippedRecordCount: contents.items.count - entries.count)
    }
}
