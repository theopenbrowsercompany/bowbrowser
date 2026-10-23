import AppKit
import BowCore

// The split view area of the adapter: E2ESplitApp over the window's store, its SplitViewFeature, its SidebarView and
// the PaneContainer that holds the panes.

extension E2ETestApp: E2ESplitApp {
    func splitState(of page: any E2EPage) throws -> E2ESplitState {
        try adapter.requireActive(token, "read the split views")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let graph = controller.store.graph
        var titles: [SidebarItemID: String] = [:]
        for tab in controller.tabList.tabs {
            if let item = controller.sidebarItemID(for: tab.id) { titles[item] = tab.title }
        }
        let title = { (item: SidebarItemID) -> String in
            if let title = titles[item], !title.isEmpty { return title }
            if case .split? = graph[item]?.data { return graph[item]?.title ?? "Split View" }
            return graph[item]?.title ?? graph[item]?.tab?.savedTitle ?? "?"
        }
        let today = graph.activeSpace.map { graph.children(of: $0.unpinnedContainerID).map(\.id) } ?? []
        let splits =
            (graph.activeSpace.map { space in
                [space.pinnedContainerID, space.unpinnedContainerID].flatMap {
                    E2EAppAdapter.splits(under: $0, in: graph)
                }
            }) ?? []
        let views = controller.paneViews
        let focused = controller.focusedPane
        let responder = controller.window?.firstResponder as? NSView
        let shown = controller.shownTabs.compactMap { controller.modelID(of: $0).flatMap(controller.sidebarItemID) }
        return E2ESplitState(
            panes: shown.map(title),
            focusedIndex: views.firstIndex { $0 === focused } ?? -1,
            activeTitle: graph.activeTabID.map(title),
            splits: splits.map { graph.splitPaneIDs($0).map(title) },
            splitFocus: splits.map { graph.focusedSplitPaneID($0).map(title) ?? "none" },
            splitWidths: splits.map { graph.splitWidthFractions($0) },
            todayItems: today.count,
            today: today.map(title),
            itemCount: graph.contentItemCount,
            closeButtons: controller.feature(SplitViewFeature.self)?.paneCloseButtons.filter {
                $0.button.superview != nil && !$0.button.isHidden
            }.count ?? 0,
            keyboardInFocused: responder.map { $0 !== focused && $0.isDescendant(of: focused) } ?? false)
    }

    func setNewTabURL(_ url: URL, of page: any E2EPage) throws {
        try adapter.requireActive(token, "set the new tab page")
        try E2EAppAdapter.tabPage(page).controller.newTabURL = url
    }

    func clickSplitSidebarRow(_ row: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click a sidebar row")
        let sidebar = try E2EAppAdapter.tabPage(page).controller.e2eSidebar
        guard row >= 0, row < sidebar.outlineView.numberOfRows else { throw E2EError("there is no row \(row)") }
        // What the outline's click action does with the clicked row.
        sidebar.clickRow(row)
    }

    func clickPaneCloseButton(at index: Int, besides page: any E2EPage) throws {
        try adapter.requireActive(token, "press a pane's close button")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let buttons = controller.feature(SplitViewFeature.self)?.paneCloseButtons ?? []
        guard buttons.indices.contains(index), buttons[index].button.superview != nil else {
            throw E2EError("pane \(index) has no close button (buttons=\(buttons.count))")
        }
        // The button's own action, as a click on it sends.
        buttons[index].button.performClick(nil)
    }

    func dragPaneDivider(_ index: Int, to fraction: Double, besides page: any E2EPage) throws {
        try adapter.requireActive(token, "drag a pane divider")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let views = controller.paneViews
        guard let container = views.first?.superview as? PaneContainer, views.count > index + 1 else {
            throw E2EError("the window shows no divider \(index) (panes=\(views.count))")
        }
        // Where AppKit's drag leaves the two panes beside the divider, then the notification it sends naming it.
        let left = views[index]
        let right = views[index + 1]
        let start = left.frame.minX
        let end = right.frame.maxX
        let position = (container.bounds.width * CGFloat(fraction)).rounded()
        guard position > start, position + container.dividerThickness < end else {
            throw E2EError("the divider cannot move to \(fraction) of the width")
        }
        left.frame = NSRect(x: left.frame.minX, y: 0, width: position - start, height: left.frame.height)
        let rightStart = position + container.dividerThickness
        right.frame = NSRect(x: rightStart, y: 0, width: end - rightStart, height: right.frame.height)
        container.splitViewDidResizeSubviews(
            Notification(
                name: NSSplitView.didResizeSubviewsNotification, object: container,
                userInfo: ["NSSplitViewDividerIndex": index]))
    }

    func relaunchWithBrokenSplits(of page: any E2EPage, lone: String) async throws -> any E2EPage {
        try adapter.requireActive(token, "relaunch with broken splits")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let file = controller.store.fileURL
        guard let space = controller.store.graph.activeSpace else { throw E2EError("the window has no Space") }
        let graphBefore = controller.store.graph
        guard
            let loneID = graphBefore.children(of: space.unpinnedContainerID).first(where: {
                $0.title == lone || $0.tab?.savedTitle == lone
            })?.id
        else { throw E2EError("today has no tab titled \(lone)") }
        try await adapter.closeWindow(of: page)
        var graph = try SidebarFileFormat.decode(Data(contentsOf: file)).graph
        var items = graph.items
        let today = space.unpinnedContainerID
        let empty = SidebarItem.split()
        var single = SidebarItem.split()
        var emptyItem = empty
        emptyItem.parentID = today
        single.parentID = today
        single.childrenIDs = [loneID]
        items[emptyItem.id] = emptyItem
        items[single.id] = single
        items[loneID]?.parentID = single.id
        var todayChildren = items[today]?.childrenIDs.filter { $0 != loneID } ?? []
        todayChildren.insert(contentsOf: [emptyItem.id, single.id], at: 0)
        items[today]?.childrenIDs = todayChildren
        graph = SidebarGraph(
            items: items, spaces: graph.spaces, favoritesContainerIDs: graph.favoritesContainerIDs,
            activeSpaceID: graph.activeSpaceID, activeTabID: graph.activeTabID)
        try SidebarFileFormat.encode(graph).write(to: file, options: .atomic)
        let store: SidebarStore
        do {
            store = try SidebarStore(fileURL: file)
        } catch {
            throw E2EError("cannot read the sidebar back from \(file.lastPathComponent): \(error)")
        }
        let delegate = adapter.delegate
        return try await adapter.showWindow(token: token) { window in
            try delegate.openWindow(url: nil, store: store, window: window)
        }
    }
}

extension E2EAppAdapter {
    /// The splits under `id`, at any depth, in sidebar order.
    static func splits(under id: SidebarItemID, in graph: SidebarGraph) -> [SidebarItemID] {
        graph.children(of: id).flatMap { child -> [SidebarItemID] in
            if case .split = child.data { return [child.id] }
            return splits(under: child.id, in: graph)
        }
    }
}
