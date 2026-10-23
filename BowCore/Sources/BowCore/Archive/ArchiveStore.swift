import Foundation

/// The archive: items auto-archive and "archive" moved out of Today, each kept whole so it can be put back exactly.
/// It lives in its own file beside the sidebar file, never inside it.
///
/// Every change is written to disk before it takes effect in memory, so a failed write leaves the store as it was.
/// The store is not thread safe: the app uses it from the main thread.
public final class ArchiveStore {
    public enum Origin: Equatable, Sendable {
        case loaded
        case freshBecauseMissing
        /// The file could not be read. It was moved to `setAsideURL` untouched and the archive starts empty.
        case freshAfterSettingAside(setAsideURL: URL, reason: String)
    }

    public struct OpenReport: Equatable, Sendable {
        public var origin: Origin
        public var migratedFrom: Int?
        /// A copy of the file as it was, kept beside it when opening had to migrate it or leave records out.
        public var backupURL: URL?
        public var skippedRecordCount: Int
    }

    /// The name of the archive file inside the app's Application Support folder, beside `Sidebar.json`.
    public static let fileName = "ArchivedItems.json"

    public let fileURL: URL
    public let openReport: OpenReport
    /// Archived entries, newest first.
    public private(set) var entries: [ArchivedEntry]

    private let writer: AtomicFileWriter

    public convenience init(fileURL: URL) throws {
        try self.init(fileURL: fileURL, migrations: ArchiveFileFormat.migrations, writer: AtomicFileWriter())
    }

    public static func fileURL(inApplicationSupportFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    init(
        fileURL: URL,
        currentVersion: Int = ArchiveFileFormat.currentVersion,
        migrations: [SidebarFileFormat.Migration],
        writer: AtomicFileWriter
    ) throws {
        self.fileURL = fileURL
        self.writer = writer
        AtomicFileWriter.removeLeftovers(for: fileURL)

        var origin = Origin.loaded
        var migratedFrom: Int?
        var backupURL: URL?
        var skipped = 0
        var entries: [ArchivedEntry] = []

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            origin = .freshBecauseMissing
        } else {
            // A file that cannot be read at all (permissions, a lock) is not known to be bad: refuse to start.
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw ArchiveError.unreadableFileNotSetAside("reading failed: \(error)")
            }
            do {
                let decoded = try ArchiveFileFormat.decode(data, currentVersion: currentVersion, migrations: migrations)
                entries = decoded.entries
                migratedFrom = decoded.migratedFrom
                skipped = decoded.skippedRecordCount
            } catch {
                let setAside = try Self.setAside(fileURL)
                origin = .freshAfterSettingAside(setAsideURL: setAside, reason: String(describing: error))
            }
        }
        // Before a later save replaces a file that had to change, keep it as it was.
        if origin == .loaded, migratedFrom != nil || skipped > 0 {
            backupURL = try Self.keepCopy(of: fileURL, suffix: migratedFrom.map { "version-\($0)" } ?? "repaired")
        }
        self.entries = Self.newestFirst(entries)
        openReport = OpenReport(
            origin: origin, migratedFrom: migratedFrom, backupURL: backupURL, skippedRecordCount: skipped)
        // The copy holds the original, so the cleaned file replaces it now; otherwise every launch would copy again.
        if backupURL != nil { try commit(self.entries) }
    }

    public func entry(for id: SidebarItemID) -> ArchivedEntry? { entries.first { $0.id == id } }

    /// The entries archived from one Space, newest first.
    public func entries(inSpace spaceID: String) -> [ArchivedEntry] { entries.filter { $0.source.spaceID == spaceID } }

    public func entries(reason: ArchivedEntry.Reason) -> [ArchivedEntry] { entries.filter { $0.reason == reason } }

    /// Adds entries and writes the file. An entry for an item that is already archived replaces the old one, so an
    /// archive that was interrupted and repeated never lists an item twice.
    public func add(_ newEntries: [ArchivedEntry]) throws(ArchiveError) {
        let replaced = Set(newEntries.map(\.id))
        try commit(Self.newestFirst(newEntries + entries.filter { !replaced.contains($0.id) }))
    }

    /// Removes entries, for example once they are put back, and writes the file. Unknown IDs are ignored.
    public func remove(_ ids: [SidebarItemID]) throws(ArchiveError) {
        let removed = Set(ids)
        guard entries.contains(where: { removed.contains($0.id) }) else { return }
        try commit(entries.filter { !removed.contains($0.id) })
    }

    /// Forgets every entry.
    public func removeAll() throws(ArchiveError) {
        guard !entries.isEmpty else { return }
        try commit([])
    }

    private func commit(_ next: [ArchivedEntry]) throws(ArchiveError) {
        do {
            try writer.write(try ArchiveFileFormat.encode(next), to: fileURL)
        } catch {
            throw .saveFailed(String(describing: error))
        }
        entries = next
    }

    /// Newest first; the ID breaks ties so the order is stable.
    private static func newestFirst(_ entries: [ArchivedEntry]) -> [ArchivedEntry] {
        entries.sorted { ($0.archivedAt, $1.id) > ($1.archivedAt, $0.id) }
    }

    // MARK: File handling

    private static func setAside(_ url: URL) throws(ArchiveError) -> URL {
        guard let destination = freeSibling(of: url, suffix: "unreadable-\(timestamp())") else {
            throw .unreadableFileNotSetAside("no free name beside \(url.lastPathComponent)")
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw .unreadableFileNotSetAside(String(describing: error))
        }
        return destination
    }

    private static func keepCopy(of url: URL, suffix: String) throws(ArchiveError) -> URL {
        guard let destination = freeSibling(of: url, suffix: suffix) else {
            throw .backupFailed("no free name beside \(url.lastPathComponent)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw .backupFailed(String(describing: error))
        }
        return destination
    }

    /// `ArchivedItems.<suffix>.json`, or `ArchivedItems.<suffix>-<n>.json` when that name is taken.
    private static func freeSibling(of url: URL, suffix: String) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        for attempt in 0..<1000 {
            let name = "\(base).\(attempt == 0 ? suffix : "\(suffix)-\(attempt)")\(fileExtension)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
