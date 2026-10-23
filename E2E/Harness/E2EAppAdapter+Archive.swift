import AppKit
import BowCore

// The archive area of the adapter: E2EArchiveApp over the app's ArchiveCenter, its e2e seam and the window's store.

extension E2ETestApp: E2EArchiveApp {
    var archiverIsRunning: Bool { adapter.archiveCenter.isRunning }

    func useManualArchiveClock() throws {
        try adapter.requireActive(token, "set the archive clock")
        _ = adapter.archiveCenter.e2eUseManualClock()
    }

    func advanceArchiveClock(by interval: TimeInterval) throws {
        try adapter.requireActive(token, "move the archive clock")
        guard let clock = adapter.archiveCenter.clock as? ManualTimeSource else {
            throw E2EError("auto-archive has no manual clock")
        }
        clock.advance(by: interval)
    }

    func runArchivePass() throws -> [String] {
        try adapter.requireActive(token, "run an archive pass")
        return adapter.archiveCenter.runPass().map(\.rawValue)
    }

    func archiveTodayTabs(besides page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the Today tabs")
        let graph = try E2EAppAdapter.tabPage(page).controller.store.graph
        guard let today = graph.activeSpace?.unpinnedContainerID else { return [] }
        func tabs(under id: SidebarItemID) -> [SidebarItemID] {
            guard let item = graph[id] else { return [] }
            return item.tab != nil ? [id] : item.childrenIDs.flatMap(tabs(under:))
        }
        return tabs(under: today).map(\.rawValue)
    }

    func archivedItems(besides page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the archive")
        let store = try E2EAppAdapter.tabPage(page).controller.store
        guard let service = adapter.archiveCenter.archiveService(for: store) else {
            throw E2EError("the window's archive cannot be opened")
        }
        return service.archived.entries.map(\.id.rawValue)
    }

    func reopenArchived(_ id: String, besides page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "reopen an archived item")
        return adapter.archiveCenter.reopen(SidebarItemID(id), in: try E2EAppAdapter.tabPage(page).controller)
    }

    func archiveItem(of page: any E2EPage) throws -> String {
        try adapter.requireActive(token, "read a tab")
        return try E2EAppAdapter.sidebarItem(of: E2EAppAdapter.tabPage(page)).rawValue
    }

    func archiveShownItem(besides page: any E2EPage) throws -> String? {
        try adapter.requireActive(token, "read the shown tab")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let tab = controller.selectedTab, let id = controller.modelID(of: tab) else { return nil }
        return controller.sidebarItemID(for: id)?.rawValue
    }

    func archiveFile(besides page: any E2EPage) throws -> URL {
        try adapter.requireActive(token, "find the archive file")
        return ArchiveCenter.archiveURL(besideSidebarFile: try E2EAppAdapter.tabPage(page).controller.store.fileURL)
    }

    func archiveSkippedRecords(besides page: any E2EPage) throws -> Int? {
        try adapter.requireActive(token, "open the archive")
        return adapter.archiveCenter.skippedRecordCount(for: try E2EAppAdapter.tabPage(page).controller.store)
    }

    func resetArchive() {
        AppSettings.defaults.removeObject(forKey: ArchiveCenter.settingsKey)
        adapter.archiveCenter.e2eReset()
    }
}

extension E2EAppAdapter {
    var archiveCenter: ArchiveCenter { delegate.appFeatures.require(ArchiveCenter.self) }
}
