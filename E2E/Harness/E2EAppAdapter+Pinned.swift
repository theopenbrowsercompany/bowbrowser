import AppKit
import BowCore

// The pinned tabs area of the adapter: E2EPinnedApp over the sidebar's context menu for a tab row, its row accessory
// and the window's store.

extension E2ETestApp: E2EPinnedApp {
    func tabMenu(of page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read a tab's menu")
        return try adapter.tabMenuItems(of: page).map { $0.isSeparatorItem ? "-" : $0.title }
    }

    func chooseTabMenuItem(_ title: String, of page: any E2EPage) throws {
        try adapter.requireActive(token, "choose a tab's menu item")
        let items = try adapter.tabMenuItems(of: page)
        guard let item = items.first(where: { $0.title == title }), item.isEnabled, let action = item.action,
            NSApp.sendAction(action, to: item.target, from: item)
        else {
            throw E2EError("no menu item \"\(title)\" in \(items.map(\.title).joined(separator: " | "))")
        }
    }

    func showsBackToPinned(_ page: any E2EPage) throws -> Bool {
        try adapter.backToPinnedButton(of: page) != nil
    }

    func clickBackToPinned(_ page: any E2EPage) throws {
        try adapter.requireActive(token, "click Back to Pinned URL")
        guard let button = try adapter.backToPinnedButton(of: page), let action = button.action,
            NSApp.sendAction(action, to: button.target, from: button)
        else { throw E2EError("the row shows no Back to Pinned URL button") }
    }

    func savedURL(of page: any E2EPage) throws -> String {
        let page = try E2EAppAdapter.tabPage(page)
        let item = try E2EAppAdapter.sidebarItem(of: page)
        return page.controller.store.graph[item]?.tab?.savedURL ?? ""
    }

    func activeTabTitle(of page: any E2EPage) throws -> String? {
        let graph = try E2EAppAdapter.tabPage(page).controller.store.graph
        return graph.activeTabID.flatMap { graph[$0]?.tab?.savedTitle }
    }
}

extension E2EAppAdapter {
    /// The context menu items of `page`'s tab row, as right clicking the row builds them.
    func tabMenuItems(of page: any E2EPage) throws -> [NSMenuItem] {
        let page = try Self.tabPage(page)
        let sidebar = page.controller.e2eSidebar
        guard let row = sidebar.row(for: try Self.sidebarItem(of: page)) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        return sidebar.menuItems(forRow: row)
    }

    /// The "Back to Pinned URL" button on `page`'s tab row, nil while the row shows none.
    func backToPinnedButton(of page: any E2EPage) throws -> NSButton? {
        let page = try Self.tabPage(page)
        let sidebar = page.controller.e2eSidebar
        guard let row = sidebar.row(for: try Self.sidebarItem(of: page)) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        let view = sidebar.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabSidebarRow
        return view?.accessoryView as? BackToPinnedButton
    }
}
