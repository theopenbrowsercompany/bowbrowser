import AppKit
import BowCore
import SQLite3

// The import history area of the adapter: E2EImportHistoryApp over the wizard's history step. The folder picker is
// answered by ArcImportFeature's seam with a User Data folder built from a fixture in a temporary folder, so no open
// panel shows and nothing outside that folder is read.

/// The User Data folder the current test built, deleted when the next one is built or the test sets none.
@MainActor
private enum E2EImportFolderState {
    static var folder: URL?
}

extension E2EAppAdapter {
    private var historyImportService: ArcImportFeature { delegate.appFeatures.require(ArcImportFeature.self) }

    @discardableResult
    func useImportFolder(_ name: String?) throws -> URL? {
        let service = historyImportService
        service.e2eFolderRequests = 0
        service.e2eLastFileLog = nil
        service.e2eChooseFolder = nil
        if let old = E2EImportFolderState.folder {
            try? FileManager.default.removeItem(at: old.deletingLastPathComponent())
            E2EImportFolderState.folder = nil
        }
        guard let name else { return nil }
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("Fixtures/import/\(name)"),
            FileManager.default.fileExists(atPath: source.path)
        else { throw E2EError("the app bundle has no Fixtures/import/\(name)") }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bow-e2e-userdata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: source, to: folder)
        E2EImportFolderState.folder = folder
        let profiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for profile in profiles {
            let script = profile.appendingPathComponent("History.sql")
            guard FileManager.default.fileExists(atPath: script.path) else { continue }
            try Self.buildDatabase(profile.appendingPathComponent("History"), from: script)
            try FileManager.default.removeItem(at: script)
        }
        service.e2eChooseFolder = { folder }
        return folder
    }

    private static func buildDatabase(_ url: URL, from script: URL) throws {
        let sql = try String(contentsOf: script, encoding: .utf8)
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw E2EError("could not build \(url.lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func importFolderRequests() -> Int { historyImportService.e2eFolderRequests }

    func importFileLog(relativeTo folder: URL) -> E2EImportFileLog? {
        guard let log = historyImportService.e2eLastFileLog else { return nil }
        let prefix = folder.standardizedFileURL.path + "/"
        let temp = ArcImportFeature.temporaryFolder.standardizedFileURL.path + "/"
        var opened: [String] = []
        var removed: [URL] = []
        for event in log.events {
            switch event {
            case .opened(let url): opened.append(url.standardizedFileURL.path)
            case .removed(let url): removed.append(url)
            case .read, .copied: break
            }
        }
        return E2EImportFileLog(
            originals: log.originals.map { $0.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "") },
            openedCount: opened.count, openedOnlyCopies: opened.allSatisfy { $0.hasPrefix(temp) },
            copiesRemoved: removed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func defaultProfileHistory() throws -> [E2EHistoryEntry] {
        guard let store = delegate.appFeatures.require(HistoryStores.self).existingStore(for: .default) else {
            return []
        }
        return try store.recent(limit: 1000).reversed().map {
            E2EHistoryEntry(url: $0.url, title: $0.title, visitCount: $0.visitCount)
        }
    }

    func pinnedRows(in page: any E2EPage) throws -> [String] {
        let graph = try Self.tabPage(page).controller.store.graph
        guard let space = graph.activeSpace else { return [] }
        var rows: [String] = []
        func add(_ container: SidebarItemID, depth: Int) {
            for item in graph.children(of: container) {
                let title: String
                if case .tab(let tab) = item.data {
                    title = item.title ?? (tab.savedTitle.isEmpty ? tab.savedURL : tab.savedTitle)
                } else {
                    title = item.title ?? ""
                }
                rows.append("\(depth):\(title)")
                add(item.id, depth: depth + 1)
            }
        }
        add(space.pinnedContainerID, depth: 0)
        return rows
    }
}

extension E2ETestApp: E2EImportHistoryApp {
    @discardableResult
    func useImportFolder(_ name: String?) throws -> URL? {
        try adapter.requireActive(token, "choose the import folder")
        return try adapter.useImportFolder(name)
    }

    func importFolderRequests() throws -> Int {
        try adapter.requireActive(token, "read the import folder requests")
        return adapter.importFolderRequests()
    }

    func importFileLog(relativeTo folder: URL) throws -> E2EImportFileLog? {
        try adapter.requireActive(token, "read the import file log")
        return adapter.importFileLog(relativeTo: folder)
    }

    func defaultProfileHistory() throws -> [E2EHistoryEntry] {
        try adapter.requireActive(token, "read the default profile's history")
        return try adapter.defaultProfileHistory()
    }

    func pinnedRows(in page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the pinned rows")
        return try adapter.pinnedRows(in: page)
    }
}
