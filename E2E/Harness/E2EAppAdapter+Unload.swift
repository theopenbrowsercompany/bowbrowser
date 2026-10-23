import AppKit
import BowCore

// The unload area of the adapter: E2EUnloadApp over the app's TabUnloader, its e2e seam and the window's tab list.

extension E2ETestApp: E2EUnloadApp {
    func setUnloadEnabled(_ enabled: Bool) throws {
        try adapter.requireActive(token, "change the unload setting")
        AppSettings.defaults.set(enabled, forKey: TabUnloader.enabledKey)
    }

    var unloaderIsRunning: Bool { adapter.unloader.isRunning }

    func useManualUnloadClock() throws {
        try adapter.requireActive(token, "set the unload clock")
        _ = adapter.unloader.e2eUseManualClock()
    }

    func advanceUnloadClock(by interval: TimeInterval) throws {
        try adapter.requireActive(token, "move the unload clock")
        guard let clock = adapter.unloader.clock as? ManualTimeSource else { throw E2EError("the unloader has no manual clock") }
        clock.advance(by: interval)
    }

    func runUnloadPass() async throws -> Int {
        try adapter.requireActive(token, "run an unload pass")
        return await adapter.unloader.runPass().count
    }

    func simulateMemoryPressure(_ level: String) async throws -> Int {
        try adapter.requireActive(token, "report memory pressure")
        let pressure: MemoryPressure
        switch level {
        case "warning": pressure = .warning
        case "critical": pressure = .critical
        default: throw E2EError("unknown memory pressure \(level)")
        }
        return await adapter.unloader.e2eSimulateMemoryPressure(pressure).count
    }

    func unloadThroughEngine(_ page: any E2EPage) async throws -> Bool {
        try adapter.requireActive(token, "unload a tab")
        return await (try E2EAppAdapter.tabPage(page)).tab.unload()
    }

    func unloadItem(of page: any E2EPage) throws -> String {
        try E2EAppAdapter.sidebarItem(of: E2EAppAdapter.tabPage(page)).rawValue
    }

    func unloadTabState(_ item: String, besides page: any E2EPage) throws -> E2EUnloadTabState {
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let row = controller.tabList.tabs.first(where: { controller.sidebarItemID(for: $0.id)?.rawValue == item })
        else {
            return E2EUnloadTabState(
                isListed: false, isLoaded: false, isShown: false, url: "", title: "", isCapturing: false)
        }
        let tab = controller.engineTab(for: row.id).flatMap { $0.isClosed ? nil : $0 }
        let state = tab?.state
        return E2EUnloadTabState(
            isListed: true, isLoaded: tab != nil, isShown: tab.map { controller.selectedTab === $0 } ?? false,
            url: (state?.url ?? row.url)?.absoluteString ?? "", title: row.title,
            isCapturing: state.map { $0.isCapturingVideo || $0.isCapturingAudio } ?? false)
    }

    func resetUnloader() {
        AppSettings.defaults.removeObject(forKey: TabUnloader.enabledKey)
        adapter.unloader.e2eReset()
    }
}

extension E2EAppAdapter {
    var unloader: TabUnloader { delegate.appFeatures.require(TabUnloader.self) }
}
