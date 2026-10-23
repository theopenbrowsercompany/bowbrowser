import Foundation

/// The sidebar file: versioned JSON holding the flat item graph and the Spaces.
///
/// The top level object has `version`, `favoritesContainerID`, `activeSpaceID`, `activeTabID`, `spaces` (in order)
/// and `items` (sorted by ID so saves are stable). Each item has `id`, `title`, `parentID`, `childrenIDs` and `data`,
/// a tagged object whose `kind` is `tab`, `folder`, `split` or `container` with the matching payload beside it.
/// History and favicons are kept out of this file.
public enum SidebarFileFormat {
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

    /// Every migration this build knows, one per older version. Version 1 is the first format, so none exist yet.
    public static let migrations: [Migration] = []

    /// Why a file could not be read. The store sets such a file aside and starts fresh.
    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notJSONObject
        case missingVersion
        /// Written by a newer build; reading it here would lose what that build added.
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

    public struct Decoded: Sendable {
        /// The graph exactly as stored, before any repair.
        public var graph: SidebarGraph
        /// The version the file was migrated from, or nil when it was already current.
        public var migratedFrom: Int?
        /// IDs that appeared more than once; the first item with each ID was kept.
        public var duplicateItemIDs: [SidebarItemID]
    }

    private struct Contents: Codable {
        var version: Int
        var favoritesContainerID: SidebarItemID
        var activeSpaceID: SidebarSpaceID?
        var activeTabID: SidebarItemID?
        var spaces: [SidebarSpace]
        var items: [SidebarItem]
    }

    public static func encode(_ graph: SidebarGraph) throws -> Data {
        let contents = Contents(
            version: currentVersion,
            favoritesContainerID: graph.favoritesContainerID,
            activeSpaceID: graph.activeSpaceID,
            activeTabID: graph.activeTabID,
            spaces: graph.spaces,
            items: graph.items.values.sorted { $0.id < $1.id })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(contents)
    }

    public static func decode(
        _ data: Data,
        currentVersion: Int = currentVersion,
        migrations: [Migration] = migrations
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

        let contents: Contents
        do {
            contents = try JSONDecoder().decode(Contents.self, from: upgraded)
        } catch {
            throw .invalidContents(String(describing: error))
        }
        var items: [SidebarItemID: SidebarItem] = [:]
        var duplicates: [SidebarItemID] = []
        for item in contents.items {
            if items[item.id] == nil { items[item.id] = item } else { duplicates.append(item.id) }
        }
        let graph = SidebarGraph(
            items: items,
            spaces: contents.spaces,
            favoritesContainerID: contents.favoritesContainerID,
            activeSpaceID: contents.activeSpaceID,
            activeTabID: contents.activeTabID)
        return Decoded(
            graph: graph, migratedFrom: version < currentVersion ? version : nil, duplicateItemIDs: duplicates)
    }
}
