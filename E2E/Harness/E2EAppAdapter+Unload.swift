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
        guard let clock = adapter.unloader.clock as? ManualTimeSource else {
            throw E2EError("the unloader has no manual clock")
        }
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
                isListed: false, isLoaded: false, isShown: false, url: "", title: "", isCapturing: false,
                isReleased: true, hasFavicon: false, isAudible: false, hasEditedForm: false)
        }
        let tab = controller.engineTab(for: row.id).flatMap { $0.isClosed ? nil : $0 }
        let state = tab?.state
        // What the row draws whenever it is shown again (a drawn row keeps its icon until its tab changes).
        let sidebar = controller.e2eSidebarFeature
        let hasFavicon = sidebar.favicon(for: SidebarItemID(item)) != nil
        // The title its row draws.
        let title = sidebar.shownTab(for: SidebarItemID(item))?.title ?? row.title
        return E2EUnloadTabState(
            isListed: true, isLoaded: tab != nil, isShown: tab.map { controller.selectedTab === $0 } ?? false,
            url: (state?.url ?? row.url)?.absoluteString ?? "", title: title,
            isCapturing: state.map { $0.isCapturingVideo || $0.isCapturingAudio } ?? false,
            isReleased: controller.engineTab(for: row.id) == nil, hasFavicon: hasFavicon,
            isAudible: state?.isAudible ?? false, hasEditedForm: state?.hasEditedForm ?? false)
    }

    func setTabAudible(_ audible: Bool, _ page: any E2EPage) throws {
        try adapter.requireActive(token, "report sound")
        guard BowUnloadProbe.setAudible(audible, forTab: try E2EAppAdapter.tabPage(page).tab.tabID.rawValue) else {
            throw E2EError("the page has no open tab")
        }
    }

    func unloadPlaceholder(besides page: any E2EPage) throws -> E2EUnloadPlaceholder {
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(TabUnloadFeature.self) else {
            throw E2EError("the window has no unload feature")
        }
        let shown = feature.e2ePlaceholder
        return E2EUnloadPlaceholder(
            item: shown?.item, title: shown?.title ?? "", inWindow: shown?.inWindow ?? false,
            log: feature.e2ePlaceholderLog)
    }

    func writeWindowScreenshot(besides page: any E2EPage, to url: URL) throws {
        try adapter.requireActive(token, "take a screenshot")
        guard let window = try E2EAppAdapter.tabPage(page).controller.window else {
            throw E2EError("the page has no window")
        }
        let png = try E2EScreenshot.png(window: window)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }

    func resetUnloader() {
        AppSettings.defaults.set(false, forKey: TabUnloader.enabledKey)
        adapter.unloader.e2eReset()
    }
}

extension E2EAppAdapter {
    var unloader: TabUnloader { delegate.appFeatures.require(TabUnloader.self) }

    /// Turns unloading off for the run before the app starts, unless a test turns it on: the app unloads by default,
    /// and the machine's own memory pressure must never unload another test's tabs.
    static func prepareUnload() {
        AppSettings.defaults.set(false, forKey: TabUnloader.enabledKey)
    }
}
