import AppKit
import BowCore

// The popups area of the adapter: E2EPopupsApp over the window controller, which takes the pages its tabs open
// through its PopupsFeature, as it does outside a test.

extension E2ETestApp: E2EPopupsApp {
    func popupTabTitles(besides page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the window's tabs")
        return try E2EAppAdapter.tabPage(page).controller.tabList.tabs.map(\.title)
    }

    func shownPopupTabTitle(besides page: any E2EPage) throws -> String? {
        try adapter.requireActive(token, "read the window's shown tab")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let shown = controller.selectedTab, let id = controller.modelID(of: shown) else { return nil }
        return controller.tabList.tabs.first { $0.id == id }?.title
    }
}
