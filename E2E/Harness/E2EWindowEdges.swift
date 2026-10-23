import AppKit
import BowCore

/// The window's edges as a test sees them: Spaces on other profiles in one window, sidebar changes made the way a
/// feature makes them (pin, delete a Space, insert a saved tab), the empty state, and the saved sidebar file.
@MainActor
protocol E2EWindowEdgesApp: E2EApp {
    var windowEdges: E2EWindowEdges { get }
}

/// Built by the adapter for one test; every action is refused once that test has ended.
@MainActor
struct E2EWindowEdges {
    let adapter: E2EAppAdapter
    let token: Int
    let requireActive: (String) throws -> Void

    private func window(of page: any E2EPage) throws -> BrowserWindowController {
        try adapter.windowAndTab(of: page).0
    }

    private func item(of page: any E2EPage) throws -> SidebarItemID {
        let (controller, tab) = try adapter.windowAndTab(of: page)
        guard let id = controller.modelID(of: tab), let item = controller.sidebarItemID(for: id) else {
            throw E2EError("the page's tab is not in its window's sidebar")
        }
        return item
    }

    private func change(_ controller: BrowserWindowController, _ body: (SidebarStore) throws -> Void) throws {
        guard controller.changeSidebar(body) else { throw E2EError("the sidebar refused the change") }
    }

    /// Creates a Space on profile `profileID` (the engine profile of that ID, which may not exist) in `page`'s
    /// window, switches to it, and returns its ID.
    func createSpace(besides page: any E2EPage, profileID: String) throws -> String {
        try requireActive("create a Space")
        let controller = try window(of: page)
        var created: SidebarSpaceID?
        try change(controller) { store in
            created = try store.createSpace(
                title: "E2E \(profileID)", profileID: SidebarStores.sidebarProfileID(of: ProfileID(profileID)))
        }
        guard let created else { throw E2EError("no Space was created") }
        return created.rawValue
    }

    /// The engine profile ID of `page`'s tab, for a second Space on the same profile.
    func profileID(of page: any E2EPage) throws -> String {
        try adapter.windowAndTab(of: page).1.profileID.rawValue
    }

    /// Opens `url` in a new tab in the Space on screen of `page`'s window and returns its page.
    func openTab(at url: URL, besides page: any E2EPage) throws -> any E2EPage {
        try requireActive("open a tab")
        let controller = try window(of: page)
        guard let tab = controller.openTab(url: url) else { throw E2EError("the window opened no tab") }
        return adapter.page(for: tab, in: controller, token: token)
    }

    /// Adds a saved tab on `url` to the today section of the Space on screen, after the active tab, without loading
    /// it (as a relaunch brings tabs back), and returns its sidebar item ID.
    func insertSavedTab(_ url: URL, besides page: any E2EPage, title: String) throws -> String {
        try requireActive("insert a saved tab")
        let controller = try window(of: page)
        let graph = controller.store.graph
        guard let space = graph.activeSpace else { throw E2EError("the window has no Space on screen") }
        let today = space.unpinnedContainerID
        let index = graph.activeTabID.flatMap { graph[today]?.childrenIDs.firstIndex(of: $0) }.map { $0 + 1 }
        let item = SidebarItem.tab(url: url.absoluteString, title: title)
        try change(controller) { try $0.apply([.insert(item, parent: today, index: index)]) }
        return item.id.rawValue
    }

    /// Selects saved tab `item` of `page`'s window the way clicking its row does.
    func selectSavedTab(_ item: String, besides page: any E2EPage) throws {
        try requireActive("select a tab")
        let controller = try window(of: page)
        guard let tab = controller.tabList.tabs.first(where: { controller.sidebarItemID(for: $0.id)?.rawValue == item })
        else { throw E2EError("tab \(item) is not listed in the window") }
        controller.select(tab.id)
    }

    /// Switches `page`'s window to Space `space`.
    func switchToSpace(_ space: String, besides page: any E2EPage) throws {
        try requireActive("switch Space")
        try change(try window(of: page)) { try $0.switchToSpace(SidebarSpaceID(space)) }
    }

    /// Deletes Space `space` of `page`'s window with every tab in it.
    func deleteSpace(_ space: String, besides page: any E2EPage) throws {
        try requireActive("delete a Space")
        try change(try window(of: page)) { _ = try $0.deleteSpace(SidebarSpaceID(space)) }
    }

    /// Pins `page`'s tab.
    func pin(_ page: any E2EPage) throws {
        try requireActive("pin a tab")
        let item = try item(of: page)
        try change(try window(of: page)) { _ = try $0.pinTab(item) }
    }

    /// The window `page` is in, as the checks read it.
    func state(of page: any E2EPage) throws -> E2EWindowState {
        let controller = try window(of: page)
        let graph = controller.store.graph
        let empty = controller.feature(EmptySpaceFeature.self)?.emptyView
        return E2EWindowState(
            isOpen: controller.window?.isVisible == true,
            rowCount: controller.tabList.count,
            loadedCount: controller.tabs.count,
            activeItem: graph.activeTabID?.rawValue,
            showsPage: controller.webView.attachedTab != nil,
            showsEmptyState: empty.map { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil } ?? false
        )
    }

    /// The sidebar file of `page`'s window as it is on disk now.
    func sidebarFile(of page: any E2EPage) throws -> String {
        let url = try window(of: page).store.fileURL
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// A window as the edge checks read it.
struct E2EWindowState {
    var isOpen: Bool
    /// Rows the window lists for the Space on screen.
    var rowCount: Int
    /// Of those, the tabs whose page is loaded.
    var loadedCount: Int
    var activeItem: String?
    /// True while the page area shows a page.
    var showsPage: Bool
    var showsEmptyState: Bool
}
