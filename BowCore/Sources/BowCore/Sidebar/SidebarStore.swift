import Foundation

/// Bowbrowser's single source of truth for the sidebar: Spaces, Favorites, pinned and unpinned tabs, folders and
/// splits, saved to one file. The engine's own session data never feeds it.
///
/// Every change goes through a transaction: `beginTransaction()`, any number of `mutate(_:)` calls, then
/// `commitTransaction()`, or `transaction { }` for the three together. A commit checks the whole graph, swaps it in and
/// writes the file atomically; a nested transaction is refused. The app calls `save()` on quit for anything a failed
/// write left unsaved.
///
/// The store is not thread safe: the app uses it from the main thread.
public final class SidebarStore {
    /// How the store came to hold its current graph.
    public enum Origin: Equatable, Sendable {
        /// The file was read.
        case loaded
        /// There was no file, so the sidebar starts empty.
        case freshBecauseMissing
        /// The file could not be read. It was moved to `setAsideURL` untouched and the sidebar starts empty.
        case freshAfterSettingAside(setAsideURL: URL, reason: String)
    }

    public struct OpenReport: Equatable, Sendable {
        public var origin: Origin
        /// The version the file was migrated from, or nil when no migration ran.
        public var migratedFrom: Int?
        /// A copy of the file as it was before migrating, kept beside it.
        public var migrationBackupURL: URL?
        /// What the cleanup pass fixed while opening; empty for a sound file.
        public var repairs: [SidebarRepair]
    }

    /// The name of the sidebar file inside the app's Application Support folder.
    public static let fileName = "Sidebar.json"

    public let fileURL: URL
    /// The committed sidebar. Changes made inside an open transaction are not visible here until commit.
    public private(set) var graph: SidebarGraph
    /// Whether the committed graph has changes the file does not have yet.
    public private(set) var hasUnsavedChanges: Bool
    public let openReport: OpenReport
    public var isInTransaction: Bool { draft != nil }

    private var draft: SidebarGraph?
    private let writer: AtomicFileWriter

    /// Opens the sidebar stored at `fileURL`, creating nothing on disk until the first save.
    ///
    /// A missing file starts an empty sidebar. A file that cannot be read, decoded or migrated is moved aside under a
    /// new name and never overwritten; if it cannot be moved, this throws `unreadableFileNotSetAside`. A readable file
    /// is migrated to the current version (keeping a copy of the original) and repaired.
    public convenience init(fileURL: URL) throws {
        try self.init(fileURL: fileURL, migrations: SidebarFileFormat.migrations, writer: AtomicFileWriter())
    }

    /// The sidebar file inside the app's Application Support folder (`~/Library/Application Support/Bow`).
    public static func fileURL(inApplicationSupportFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    init(
        fileURL: URL,
        currentVersion: Int = SidebarFileFormat.currentVersion,
        migrations: [SidebarFileFormat.Migration],
        writer: AtomicFileWriter
    ) throws {
        self.fileURL = fileURL
        self.writer = writer
        AtomicFileWriter.removeLeftovers(for: fileURL)

        var origin = Origin.loaded
        var migratedFrom: Int?
        var backupURL: URL?
        var repairs: [SidebarRepair] = []
        var graph: SidebarGraph

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            graph = .fresh()
            origin = .freshBecauseMissing
        } else {
            do {
                let data = try Self.read(fileURL)
                let decoded = try SidebarFileFormat.decode(data, currentVersion: currentVersion, migrations: migrations)
                graph = decoded.graph
                repairs = decoded.duplicateItemIDs.map { .droppedDuplicateItem($0) }
                if let version = decoded.migratedFrom {
                    migratedFrom = version
                    backupURL = try Self.keepCopy(of: fileURL, suffix: "version-\(version)")
                }
            } catch let error as SidebarStoreError {
                throw error
            } catch {
                let setAside = try Self.setAside(fileURL)
                graph = .fresh()
                origin = .freshAfterSettingAside(setAsideURL: setAside, reason: String(describing: error))
            }
        }

        repairs += graph.repair()
        self.graph = graph
        hasUnsavedChanges = origin != .loaded || migratedFrom != nil || !repairs.isEmpty
        openReport = OpenReport(
            origin: origin, migratedFrom: migratedFrom, migrationBackupURL: backupURL, repairs: repairs)
    }

    // MARK: Transactions

    /// Opens a transaction on a private copy of the graph. Refused while another transaction is open.
    public func beginTransaction() throws(SidebarStoreError) {
        guard draft == nil else { throw .nestedTransaction }
        draft = graph
    }

    /// Applies one change to the open transaction. A refused change leaves the transaction as it was, still open.
    public func mutate(_ mutation: SidebarMutation) throws(SidebarStoreError) {
        guard draft != nil else { throw .noOpenTransaction }
        try draft!.apply(mutation)
    }

    /// The graph as the open transaction currently sees it.
    public var transactionGraph: SidebarGraph? { draft }

    /// Checks the transaction's graph, makes it the committed graph and writes the file.
    ///
    /// If the check fails, the transaction is rolled back and `integrityCheckFailed` is thrown. If only the write
    /// fails, the change stays committed in memory, `hasUnsavedChanges` stays true, and `saveFailed` is thrown; the
    /// file on disk keeps its previous contents.
    public func commitTransaction() throws(SidebarStoreError) {
        guard let draft else { throw .noOpenTransaction }
        self.draft = nil
        guard draft != graph else { return }
        let problems = draft.integrityProblems()
        guard problems.isEmpty else { throw .integrityCheckFailed(problems) }
        graph = draft
        hasUnsavedChanges = true
        try save()
    }

    /// Discards the open transaction.
    public func rollbackTransaction() {
        draft = nil
    }

    /// Runs `body` in a transaction and commits it, or rolls everything back if `body` or the commit's check throws.
    public func transaction(_ body: () throws -> Void) throws {
        try beginTransaction()
        do {
            try body()
        } catch {
            rollbackTransaction()
            throw error
        }
        try commitTransaction()
    }

    /// Applies `mutations` in one transaction.
    public func apply(_ mutations: [SidebarMutation]) throws {
        try transaction {
            for mutation in mutations { try mutate(mutation) }
        }
    }

    // MARK: Saving and repair

    /// Writes the committed graph if the file is behind it. The app calls this on quit.
    public func save() throws(SidebarStoreError) {
        guard draft == nil else { throw .transactionInProgress }
        guard hasUnsavedChanges else { return }
        do {
            try writer.write(try SidebarFileFormat.encode(graph), to: fileURL)
        } catch {
            throw .saveFailed(String(describing: error))
        }
        hasUnsavedChanges = false
    }

    /// Runs the cleanup pass on the committed graph and saves if it changed anything.
    @discardableResult
    public func repair() throws(SidebarStoreError) -> [SidebarRepair] {
        guard draft == nil else { throw .transactionInProgress }
        var repaired = graph
        let repairs = repaired.repair()
        guard !repairs.isEmpty else { return [] }
        graph = repaired
        hasUnsavedChanges = true
        try save()
        return repairs
    }

    // MARK: File handling

    private static func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Moves an unreadable file to a new name beside it, never replacing an earlier one.
    private static func setAside(_ url: URL) throws(SidebarStoreError) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        for attempt in 0..<100 {
            let destination = sibling(of: url, suffix: "unreadable-\(stamp)" + (attempt == 0 ? "" : "-\(attempt)"))
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            } catch {
                throw .unreadableFileNotSetAside(String(describing: error))
            }
        }
        throw .unreadableFileNotSetAside("no free name beside \(url.lastPathComponent)")
    }

    /// Copies the file before migrating it, unless a copy with that name already exists.
    private static func keepCopy(of url: URL, suffix: String) throws(SidebarStoreError) -> URL {
        let destination = sibling(of: url, suffix: suffix)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return destination }
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw .migrationBackupFailed(String(describing: error))
        }
        return destination
    }

    /// `Sidebar.json` with suffix `x` becomes `Sidebar.x.json` in the same folder.
    private static func sibling(of url: URL, suffix: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(suffix)\(fileExtension)")
    }
}
