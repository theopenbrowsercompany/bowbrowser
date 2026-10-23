import AppKit
import BowCore

// The sidebar and zones area of the adapter: E2ESidebarApp and E2EZonesApp over the window controller and its
// SidebarView. Each area keeps its adapter code in a file like this one, E2EAppAdapter+<Area>.swift, next to its
// protocol in its own E2E/Harness file; together the adapter files are the only harness code that knows the app.
// The test's app (E2ETestApp) offers these commands to the test after checking that the test is still running.

extension E2ETestApp: E2ESidebarApp {
    func sidebarRows(of page: any E2EPage) throws -> [E2ESidebarRow] {
        try adapter.sidebarRows(of: page)
    }

    func sidebarRowHistory(of page: any E2EPage) -> [E2ESidebarRow] {
        adapter.sidebarRowHistory(of: page)
    }

    func clickSidebarRow(of page: any E2EPage) throws {
        try adapter.requireActive(token, "click a sidebar row")
        try adapter.clickSidebarRow(of: page)
    }

    func clickSidebarClose(of page: any E2EPage) throws {
        try adapter.requireActive(token, "click a sidebar close button")
        try adapter.clickSidebarClose(of: page)
    }

    func clickNewTab(besides page: any E2EPage, opening url: URL) throws -> any E2EPage {
        try adapter.requireActive(token, "click the New Tab button")
        return try adapter.clickNewTab(besides: page, opening: url, token: token)
    }

    func chooseMenuItem(commandKey key: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose the menu item for Command-\(key)")
        try adapter.chooseMenuItem(key: key, modifiers: .command, in: page)
    }

    func moveTab(_ page: any E2EPage, to index: Int) throws {
        try adapter.requireActive(token, "move a tab")
        try adapter.moveTab(page, to: index)
    }
}

extension E2ETestApp: E2EZonesApp {
    func sidebarOutline(of page: any E2EPage) throws -> [String] {
        try adapter.sidebarOutline(of: page)
    }

    func sidebarOutlineRows(of page: any E2EPage) throws -> [E2EOutlineRow] {
        try adapter.sidebarOutlineRows(of: page)
    }

    func sidebarZone(of page: any E2EPage) throws -> String? {
        try adapter.sidebarZone(of: page)
    }

    func dragTab(_ page: any E2EPage, onRow row: Int?, childIndex: Int) throws {
        try adapter.requireActive(token, "drag a tab")
        try adapter.dragTab(page, onRow: row, childIndex: childIndex)
    }
}

// The sidebar and tab commands over the window controller and its SidebarView.
extension E2EAppAdapter {
    func sidebarRows(of page: any E2EPage) throws -> [E2ESidebarRow] {
        let controller = try Self.tabPage(page).controller
        return controller.tabs.compactMap { Self.sidebarRow(of: $0, in: controller) }
    }

    func sidebarRowHistory(of page: any E2EPage) -> [E2ESidebarRow] {
        (page as? E2ETabPage)?.sidebarRowHistory ?? []
    }

    /// The row of `tab` as the sidebar draws it, made if the outline has not laid it out yet.
    static func sidebarRow(of tab: any EngineTab, in controller: BrowserWindowController)
        -> E2ESidebarRow?
    {
        guard let id = controller.modelID(of: tab), let item = controller.sidebarItemID(for: id),
            let row = controller.e2eSidebar.row(for: item)
        else { return nil }
        let outline = controller.e2eSidebar.outlineView
        guard let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? TabSidebarRow else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        return E2ESidebarRow(
            title: view.titleField.stringValue,
            isLoading: view.isLoading,
            hasFavicon: view.hasFavicon,
            isActive: outline.rowView(atRow: row, makeIfNecessary: true)?.isSelected ?? false,
            titleClearsClose: view.titleField.frame.maxX <= view.closeButton.frame.minX
        )
    }

    /// The sidebar item of `page`'s tab.
    static func sidebarItem(of page: E2ETabPage) throws -> SidebarItemID {
        guard let id = page.controller.modelID(of: page.tab), let item = page.controller.sidebarItemID(for: id) else {
            throw E2EError("tab \(page.tab.tabID) is not in its window's sidebar")
        }
        return item
    }

    func clickSidebarRow(of page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        guard let row = page.controller.e2eSidebar.row(for: try Self.sidebarItem(of: page)) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        // What the outline's click action does with the clicked row.
        page.controller.e2eSidebar.clickRow(row)
    }

    func clickSidebarClose(of page: any E2EPage) throws {
        let page = try Self.tabPage(page)
        guard let view = page.controller.e2eSidebar.rowView(for: try Self.sidebarItem(of: page)) else {
            throw E2EError("tab \(page.tab.tabID) has no sidebar row")
        }
        guard !view.closeButton.isHidden else { throw E2EError("the row's close button is not showing") }
        try Self.click(view.closeButton)
    }

    func clickNewTab(besides page: any E2EPage, opening url: URL, token: Int) throws -> any E2EPage {
        let controller = try Self.tabPage(page).controller
        let before = Set(controller.tabs.map(\.tabID))
        controller.newTabURL = url
        try Self.click(controller.e2eSidebar.newTabButton)
        guard let tab = controller.tabs.first(where: { !before.contains($0.tabID) }) else {
            throw E2EError("the New Tab button opened no tab")
        }
        return track(tab, in: controller, token: token)
    }

    /// Sends `button`'s action to its target, as a click on it ends up doing. `performClick(_:)` is not used: it
    /// runs the run loop while it shows the button pressed, so the engine's events for a tab the click opens
    /// would arrive before the test could track the tab.
    private static func click(_ button: NSButton) throws {
        guard button.isEnabled, !button.isHiddenOrHasHiddenAncestor, let action = button.action,
            NSApp.sendAction(action, to: button.target, from: button)
        else {
            throw E2EError("the button \"\(button.accessibilityLabel() ?? button.title)\" cannot be clicked")
        }
    }

    func moveTab(_ page: any E2EPage, to index: Int) throws {
        let page = try Self.tabPage(page)
        guard let id = page.controller.modelID(of: page.tab) else {
            throw E2EError("tab \(page.tab.tabID) is not in its window")
        }
        guard page.controller.e2eSidebarFeature.dropTab(id, atTabIndex: index) else {
            throw E2EError("the sidebar refused to move the tab to \(index)")
        }
    }

    func sidebarOutline(of page: any E2EPage) throws -> [String] {
        try sidebarOutlineRows(of: page).map(\.title)
    }

    func sidebarOutlineRows(of page: any E2EPage) throws -> [E2EOutlineRow] {
        let sidebar = try Self.tabPage(page).controller.e2eSidebar
        let outline = sidebar.outlineView
        return sidebar.rowKinds().enumerated().map { row, kind in
            let title: String
            if let section = kind.section {
                title = section.zone?.rawValue ?? "divider"
            } else {
                let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                title =
                    (view as? TabSidebarRow)?.titleField.stringValue
                    ?? (view as? SidebarGroupRow)?.titleField.stringValue ?? "?"
            }
            return E2EOutlineRow(title: title, level: outline.level(forRow: row))
        }
    }

    func sidebarZone(of page: any E2EPage) throws -> String? {
        let page = try Self.tabPage(page)
        return page.controller.e2eSidebar.zone(of: try Self.sidebarItem(of: page))?.rawValue
    }

    func dragTab(_ page: any E2EPage, onRow row: Int?, childIndex: Int) throws {
        let page = try Self.tabPage(page)
        let item = try Self.sidebarItem(of: page)
        // The outline's own drop routing: the proposal (with its retargeted gap), then the accepted drop.
        guard page.controller.e2eSidebar.dragItem(item, onRow: row, childIndex: childIndex) else {
            let place = row.map { "row \($0)" } ?? "between sections"
            throw E2EError("the sidebar refused to drop the tab on \(place) at \(childIndex)")
        }
    }
}
