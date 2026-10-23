import Foundation

/// The saved routing table: one versioned JSON file (`LinkRouting.json`) beside the sidebar file, written atomically
/// after every change.
///
/// Opening never loses the person's rules: a missing file starts from `RoutingTable.initial`; a file written by a
/// newer Bow is left untouched and nothing is saved over it (routing uses the initial table meanwhile, and the editor
/// says why it cannot change anything); a file that cannot be read is moved aside under a new name, untouched, and
/// routing starts from the initial table.
///
/// The store is not thread safe: the app uses it from the main thread.
public final class RoutingStore {
    /// The name of the file inside the app's Application Support folder.
    public static let fileName = "LinkRouting.json"

    /// How the store came to hold its table.
    public enum Origin: Equatable, Sendable {
        case loaded
        case freshBecauseMissing
        /// The file was written by a newer Bow in format `version`. It stays as it is and the store never saves.
        case newerFile(version: Int)
        /// The file could not be read. It was moved to `setAsideURL`, untouched.
        case freshAfterSettingAside(setAsideURL: URL, reason: String)
        /// The file could not be read nor moved aside: it stays as it is and the store never saves.
        case unreadable(reason: String)
    }

    public enum SaveError: Error, Equatable, CustomStringConvertible {
        /// The store refuses to write over a file it could not read or that a newer Bow wrote.
        case readOnly
        case writeFailed(String)

        public var description: String {
            switch self {
            case .readOnly: "the routing file was left untouched, so changes are not saved"
            case .writeFailed(let reason): "the routing file could not be written (\(reason))"
            }
        }
    }

    public let fileURL: URL
    public let origin: Origin
    public private(set) var table: RoutingTable

    /// True when changes are saved; false when the file is a newer Bow's or could not be read nor set aside.
    public var canSave: Bool {
        switch origin {
        case .newerFile, .unreadable: false
        case .loaded, .freshBecauseMissing, .freshAfterSettingAside: true
        }
    }

    public static func fileURL(inApplicationSupportFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            table = .initial
            origin = .freshBecauseMissing
            return
        } catch {
            // A file that exists but cannot be read is left alone: it may come back once its permissions are fixed.
            table = .initial
            origin = .unreadable(reason: String(describing: error))
            return
        }
        do {
            table = try JSONDecoder().decode(RoutingTable.self, from: data)
            origin = .loaded
        } catch RoutingTable.DecodingFailure.unsupportedVersion(let version) {
            table = .initial
            origin = .newerFile(version: version)
        } catch {
            table = .initial
            let reason = String(describing: error)
            if let aside = Self.setAside(fileURL) {
                origin = .freshAfterSettingAside(setAsideURL: aside, reason: reason)
            } else {
                origin = .unreadable(reason: reason)
            }
        }
    }

    /// Replaces the table and writes it. Throws, keeping the new table in memory for this run, when the store may not
    /// save or the write fails.
    public func update(_ table: RoutingTable) throws(SaveError) {
        self.table = table
        guard canSave else { throw .readOnly }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(table)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw .writeFailed(String(describing: error))
        }
    }

    /// Moves an unreadable file to a new name beside it, never replacing an earlier one. Nil when it cannot.
    private static func setAside(_ url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date())
        for index in 0..<100 {
            let suffix = index == 0 ? "" : "-\(index)"
            let candidate = folder.appendingPathComponent("\(stem).unreadable-\(stamp)\(suffix).\(url.pathExtension)")
            guard !FileManager.default.fileExists(atPath: candidate.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: candidate)
                return candidate
            } catch {
                return nil
            }
        }
        return nil
    }
}
