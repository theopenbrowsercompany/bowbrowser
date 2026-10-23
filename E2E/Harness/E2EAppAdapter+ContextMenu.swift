import AppKit
import BowCore

// The context menu area of the adapter: E2EContextMenuApp over the engine adapter's menu chooser seam
// (`CEFTab.e2eMenuChooser`) and the DevTools requests the engine records in e2e runs. The chooser stays installed
// after the test; once the test has ended it chooses nothing and records nothing.

extension E2ETestApp: E2EContextMenuApp {
    func chooseContextMenuItem(_ title: String?) throws {
        try adapter.requireActive(token, "choose a context menu item")
        let adapter = adapter
        let token = token
        if E2EContextMenus.token != token {
            E2EContextMenus.token = token
            E2EContextMenus.menus = []
        }
        CEFTab.e2eMenuChooser = { request, items in
            guard (try? adapter.requireActive(token, "answer a context menu")) != nil else { return nil }
            let chosen = title.flatMap { items.contains($0) ? $0 : nil }
            E2EContextMenus.menus.append(E2EContextMenu(linkURL: request.linkURL, items: items, chosen: chosen))
            return chosen
        }
    }

    func contextMenus() throws -> [E2EContextMenu] {
        try adapter.requireActive(token, "read context menus")
        return E2EContextMenus.token == token ? E2EContextMenus.menus : []
    }

    func devToolsRequests(of page: any E2EPage) throws -> (count: Int, point: CGPoint?) {
        try adapter.requireActive(token, "read DevTools requests")
        let tabID = try E2EAppAdapter.tabPage(page).tab.tabID.rawValue
        let point = BowOpenBrowsers.devToolsInspectedPoint(forTab: tabID)
        return (BowOpenBrowsers.devToolsRequests(forTab: tabID), point.x < 0 ? nil : point)
    }

    var screenState: String {
        let visible = NSApp.windows.filter(\.isVisible)
        let onScreen = visible.filter { window in NSScreen.screens.contains { $0.frame.intersects(window.frame) } }
        return "windows=\(visible.count) on-screen=\(onScreen.count) active=\(NSApp.isActive)"
            + " dock=\(NSApp.activationPolicy() == .regular)"
    }
}

/// The menus recorded for the test whose token is `token`.
@MainActor
enum E2EContextMenus {
    static var token = -1
    static var menus: [E2EContextMenu] = []
}
