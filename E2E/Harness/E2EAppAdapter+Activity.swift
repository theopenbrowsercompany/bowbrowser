import AppKit
import BowCore

// The tab activity area of the adapter: E2EActivityApp over the app's TabActivityLog.

extension E2EAppAdapter {
    func activityTime(of page: any E2EPage) throws -> Date? {
        let page = try Self.tabPage(page)
        let controller = page.controller
        guard let id = controller.modelID(of: page.tab), let item = controller.sidebarItemID(for: id) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar item")
        }
        return controller.appFeatures.require(TabActivityLog.self).lastActive(item)
    }
}

extension E2ETestApp: E2EActivityApp {
    func activityTime(of page: any E2EPage) throws -> Date? {
        try adapter.activityTime(of: page)
    }
}
