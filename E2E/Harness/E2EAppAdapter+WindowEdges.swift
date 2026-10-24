import AppKit
import BowCore

// The window edges area of the adapter: E2EWindowEdgesApp over the window controller, its sidebar store, its empty
// state and its web view. The test's app (E2ETestApp) offers these commands to the test after checking that the test
// is still running.

extension E2ETestApp: E2EWindowEdgesApp {
    func createSpace(besides page: any E2EPage, profileID: String) throws -> String {
        try adapter.requireActive(token, "create a Space")
        return try adapter.createSpace(besides: page, profileID: profileID)
    }

    func profileID(of page: any E2EPage) throws -> String {
        try Self.window(of: page).tab.profileID.rawValue
    }

    func insertSavedTab(_ url: URL, besides page: any E2EPage, title: String) throws -> String {
        try adapter.requireActive(token, "insert a saved tab")
        return try adapter.insertSavedTab(url, besides: page, title: title)
    }

    func selectSavedTab(_ item: String, besides page: any E2EPage) throws {
        try adapter.requireActive(token, "select a tab")
        try adapter.selectSavedTab(item, besides: page)
    }

    func switchToSpace(_ space: String, besides page: any E2EPage) throws {
        try adapter.requireActive(token, "switch Space")
        try adapter.changeSidebar(of: page) { try $0.switchToSpace(SidebarSpaceID(space)) }
    }

    func activeSpace(besides page: any E2EPage) throws -> String {
        guard let id = try Self.window(of: page).controller.store.graph.activeSpaceID else {
            throw E2EError("the window has no Space on screen")
        }
        return id.rawValue
    }

    func deleteSpace(_ space: String, besides page: any E2EPage) throws {
        try adapter.requireActive(token, "delete a Space")
        try adapter.changeSidebar(of: page) { _ = try $0.deleteSpace(SidebarSpaceID(space)) }
    }

    func pin(_ page: any E2EPage) throws {
        try adapter.requireActive(token, "pin a tab")
        let item = try E2EAppAdapter.sidebarItem(of: Self.window(of: page))
        try adapter.changeSidebar(of: page) { _ = try $0.pinTab(item) }
    }

    func requestWindowClose(of page: any E2EPage) throws {
        try adapter.requireActive(token, "ask a window to close")
        guard let window = try Self.window(of: page).controller.window else {
            throw E2EError("the page has no window")
        }
        window.performClose(nil)
    }

    func sameWindow(_ page: any E2EPage, _ other: any E2EPage) throws -> Bool {
        try Self.window(of: page).controller === Self.window(of: other).controller
    }

    func clickLoadTab(besides page: any E2EPage) throws {
        try adapter.requireActive(token, "click Load Tab")
        let view = try Self.window(of: page).controller.e2eEmptySpace
        guard !view.isHiddenOrHasHiddenAncestor, !view.loadTabButton.isHidden else {
            throw E2EError("the window shows no Load Tab button")
        }
        view.loadTabButton.performClick(nil)
    }

    func windowState(of page: any E2EPage) throws -> E2EWindowState {
        try adapter.windowState(of: page)
    }

    func sidebarFile(of page: any E2EPage) throws -> String {
        let url = try Self.window(of: page).controller.store.fileURL
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func sidebarFileModified(of page: any E2EPage) throws -> Date? {
        let url = try Self.window(of: page).controller.store.fileURL
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    var recordSaveDelay: TimeInterval { BrowserWindowController.recordSaveDelay }

    private static func window(of page: any E2EPage) throws -> E2ETabPage {
        try E2EAppAdapter.tabPage(page)
    }
}

// The window edge commands over the window controller and its sidebar store.
extension E2EAppAdapter {
    /// Runs `body` on the store of `page`'s window the way a feature does, failing when the store refuses it.
    func changeSidebar(of page: any E2EPage, _ body: (SidebarStore) throws -> Void) throws {
        guard try Self.tabPage(page).controller.changeSidebar(body) else {
            throw E2EError("the sidebar refused the change")
        }
    }

    func createSpace(besides page: any E2EPage, profileID: String) throws -> String {
        var created: SidebarSpaceID?
        try changeSidebar(of: page) { store in
            created = try store.createSpace(
                title: "E2E \(profileID)", profileID: SidebarStores.sidebarProfileID(of: ProfileID(profileID)))
        }
        guard let created else { throw E2EError("no Space was created") }
        return created.rawValue
    }

    func insertSavedTab(_ url: URL, besides page: any E2EPage, title: String) throws -> String {
        let graph = try Self.tabPage(page).controller.store.graph
        guard let space = graph.activeSpace else { throw E2EError("the window has no Space on screen") }
        let today = space.unpinnedContainerID
        let index = graph.activeTabID.flatMap { graph[today]?.childrenIDs.firstIndex(of: $0) }.map { $0 + 1 }
        let item = SidebarItem.tab(url: url.absoluteString, title: title)
        try changeSidebar(of: page) { try $0.apply([.insert(item, parent: today, index: index)]) }
        return item.id.rawValue
    }

    func selectSavedTab(_ item: String, besides page: any E2EPage) throws {
        let controller = try Self.tabPage(page).controller
        guard let tab = controller.tabList.tabs.first(where: { controller.sidebarItemID(for: $0.id)?.rawValue == item })
        else { throw E2EError("tab \(item) is not listed in the window") }
        controller.select(tab.id)
    }

    func windowState(of page: any E2EPage) throws -> E2EWindowState {
        let controller = try Self.tabPage(page).controller
        let empty = controller.e2eEmptySpace
        let shown = !empty.isHiddenOrHasHiddenAncestor && empty.window != nil
        return E2EWindowState(
            isOpen: controller.window?.isVisible == true,
            rowCount: controller.tabList.count,
            loadedCount: controller.tabs.count,
            activeItem: controller.store.graph.activeTabID?.rawValue,
            showsPage: controller.webView.showsTab,
            showsEmptyState: shown,
            showsUnloadedTab: shown && empty.showsUnloadedTab,
            activeTitle: controller.tabList.activeTab?.title ?? ""
        )
    }
}

extension BrowserWindowController {
    var e2eEmptySpace: EmptySpaceView { feature(EmptySpaceFeature.self)!.emptyView }
}
