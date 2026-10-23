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
                isReleased: true, hasFavicon: false)
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
            isReleased: controller.engineTab(for: row.id) == nil, hasFavicon: hasFavicon)
    }

    func unloadDialogShown(besides page: any E2EPage) throws -> Bool {
        let window = try E2EAppAdapter.tabPage(page).controller.window
        return NSApp.modalWindow != nil || window?.attachedSheet != nil
    }

    func cancelUnloadDialog(besides page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "answer a dialog")
        if let panel = NSApp.modalWindow {
            // The engine's alert panel answers the page only through its own buttons: stopping its modal session
            // leaves it up until AppKit next serves that session (a posted event does not), and ending it as a sheet
            // hides it without answering the page. So press its Cancel button (a confirm or prompt's second), or an
            // alert's only button, as a person does.
            func buttons(in view: NSView) -> [NSButton] {
                ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
            }
            let shown = panel.contentView.map { buttons(in: $0) } ?? []
            func button(_ response: NSApplication.ModalResponse) -> NSButton? {
                shown.first { $0.tag == response.rawValue }
            }
            guard let button = button(.alertSecondButtonReturn) ?? button(.alertFirstButtonReturn) else {
                throw E2EError("the dialog panel has no button to press")
            }
            button.performClick(nil)
            return true
        }
        guard let window = try E2EAppAdapter.tabPage(page).controller.window, let sheet = window.attachedSheet
        else { return false }
        window.endSheet(sheet, returnCode: .cancel)
        return true
    }

    func resetUnloader() {
        AppSettings.defaults.removeObject(forKey: TabUnloader.enabledKey)
        adapter.unloader.e2eReset()
    }
}

extension E2EAppAdapter {
    var unloader: TabUnloader { delegate.appFeatures.require(TabUnloader.self) }
}
