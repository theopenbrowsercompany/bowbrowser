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
        /// The file could not be read. It was moved to `setAsideURL` untouched and the sidebar starts empty. The app
        /// tells the person, with that path, so they can recover it.
        case freshAfterSettingAside(setAsideURL: URL, reason: String)
    }

    public struct OpenReport: Equatable, Sendable {
        public var origin: Origin
        /// The version the file was migrated from, or nil when no migration ran.
        public var migratedFrom: Int?
        /// A copy of the file as it was, kept beside it when opening had to migrate or repair it.
        public var backupURL: URL?
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
    /// What the most recent commit did to split views that a change left with too few tabs (removed, dissolved into
    /// the remaining tab) or too many. Empty when it did none, and replaced by every commit, so a caller reads it right
    /// after the commit it cares about.
    public private(set) var lastCommitRepairs: [SidebarRepair] = []
    public let openReport: OpenReport
    public var isInTransaction: Bool { draft != nil }

    private var draft: SidebarGraph?
    private let writer: AtomicFileWriter

    /// Opens the sidebar stored at `fileURL`, creating nothing on disk until the first save.
    ///
    /// A missing file starts an empty sidebar. A file written by a newer Bow is left where it is and this throws
    /// `fileFromNewerBuild`. Any other file that cannot be read, decoded or migrated is moved aside under a new name
    /// and never overwritten; if it cannot be moved, this throws `unreadableFileNotSetAside`. A readable file is
    /// migrated to the current version (keeping a copy of the original) and repaired.
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
                if decoded.skippedRecordCount > 0 {
                    repairs.append(.skippedUnreadableRecords(decoded.skippedRecordCount))
                }
                migratedFrom = decoded.migratedFrom
            } catch SidebarFileFormat.ReadError.newerVersion(let version) {
                // A newer Bow shares this folder; setting its file aside would cost it the sidebar. Leave it alone.
                throw SidebarStoreError.fileFromNewerBuild(version: version, readable: currentVersion)
            } catch {
                let setAside = try Self.setAside(fileURL)
                graph = .fresh()
                origin = .freshAfterSettingAside(setAsideURL: setAside, reason: String(describing: error))
            }
        }

        // Only once the file is known to be this build's: a newer Bow's save in progress is not this build's to clear.
        AtomicFileWriter.removeLeftovers(for: fileURL)
        repairs += graph.repair()
        // Before the first save replaces a file that had to change, keep it as it was.
        if origin == .loaded, let version = migratedFrom {
            backupURL = try Self.keepCopy(of: fileURL, suffix: "version-\(version)")
        } else if origin == .loaded, !repairs.isEmpty {
            backupURL = try Self.keepCopy(of: fileURL, suffix: "repaired-\(Self.timestamp())")
        }
        self.graph = graph
        hasUnsavedChanges = origin != .loaded || migratedFrom != nil || !repairs.isEmpty
        openReport = OpenReport(
            origin: origin, migratedFrom: migratedFrom, backupURL: backupURL, repairs: repairs)
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

    /// Applies the split rules to the transaction's graph (a split with no tabs goes, one with one tab turns back into
    /// that tab), checks it, makes it the committed graph and writes the file.
    ///
    /// If the check fails, the transaction is rolled back and `integrityCheckFailed` is thrown. If only the write
    /// fails, the change stays committed in memory, `hasUnsavedChanges` stays true, and `saveFailed` is thrown; the
    /// file on disk keeps its previous contents.
    public func commitTransaction() throws(SidebarStoreError) {
        guard var draft else { throw .noOpenTransaction }
        self.draft = nil
        // A split left with fewer than two tabs by any change (a move to Favorites or another Space, a delete) is
        // cleaned up here, so no path has to remember it and a committed graph never holds one.
        var splitFixes: [SidebarRepair] = []
        draft.repairSplits(&splitFixes, previous: graph)
        guard draft != graph else {
            // Nothing changed, but retry a write an earlier commit could not finish.
            lastCommitRepairs = []
            try save()
            return
        }
        let problems = draft.integrityProblems()
        guard problems.isEmpty else {
            lastCommitRepairs = []
            throw .integrityCheckFailed(problems)
        }
        graph = draft
        lastCommitRepairs = splitFixes
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

    /// Copies the file to a new name beside it, never replacing an earlier copy.
    private static func keepCopy(of url: URL, suffix: String) throws(SidebarStoreError) -> URL {
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

    /// `Sidebar.<suffix>.json`, or `Sidebar.<suffix>-<n>.json` when that name is taken.
    private static func freeSibling(of url: URL, suffix: String) -> URL? {
        for attempt in 0..<1000 {
            let candidate = sibling(of: url, suffix: attempt == 0 ? suffix : "\(suffix)-\(attempt)")
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

    /// `Sidebar.json` with suffix `x` becomes `Sidebar.x.json` in the same folder.
    private static func sibling(of url: URL, suffix: String) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let fileExtension = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent("\(base).\(suffix)\(fileExtension)")
    }
}
