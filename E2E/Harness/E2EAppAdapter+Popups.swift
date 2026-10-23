import AppKit
import BowCore

// The popups area of the adapter: E2EPopupsApp over the window controller, which takes the pages its tabs open
// through its PopupsFeature, as it does outside a test, and shows popup panels through its PopupPanelFeature.

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

    func popupPanels(besides page: any E2EPage) throws -> [E2EPopupPanel] {
        try adapter.requireActive(token, "read the window's popup panels")
        let parent = try E2EAppAdapter.tabPage(page).controller.window
        return try panelWindows(besides: page).map { panel in
            E2EPopupPanel(
                contentSize: panel.contentRect(forFrameRect: panel.frame).size,
                attached: parent != nil && panel.parent === parent,
                intrudes: panel.isKeyWindow || NSScreen.screens.contains { $0.frame.intersects(panel.frame) },
                title: panel.title,
                frame: panel.frame,
                parentFrame: parent?.frame ?? .zero)
        }
    }

    func closePopupPanel(besides page: any E2EPage) throws {
        try adapter.requireActive(token, "close a popup panel")
        guard let panel = try panelWindows(besides: page).first else { throw E2EError("no popup panel is open") }
        panel.performClose(nil)
    }

    func untilNoPopupPanels(besides page: any E2EPage) async throws {
        try adapter.requireActive(token, "wait for the popup panels to close")
        // Looks again every 50 ms until the panels are gone, as E2EEngineProbe.until does: a panel closes on its page's
        // closed event, which reaches the app on a main thread task of its own.
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while let panel = try panelWindows(besides: page).first {
            guard Date() < deadline else { throw E2EError("a popup panel (\(panel.title)) was still open") }
            try await Task.sleep(nanoseconds: 50_000_000)
            try adapter.requireActive(token, "wait for the popup panels to close")
        }
    }

    /// The popup panel windows attached to `page`'s window, oldest first, also those a closed window ordered out.
    private func panelWindows(besides page: any E2EPage) throws -> [PopupPanelWindow] {
        let parent = try E2EAppAdapter.tabPage(page).controller.window
        return (parent?.childWindows ?? []).compactMap { $0 as? PopupPanelWindow }
    }
}
