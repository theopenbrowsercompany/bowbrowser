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
            keyboardInFocused: responder.map { $0 !== focused && $0.isDescendant(of: focused) } ?? false,
            splitOrientations: splits.map { graph.split($0)?.orientation.rawValue ?? "?" },
            pinned: graph.activeSpace.map { graph.children(of: $0.pinnedContainerID).map(\.id).map(title) } ?? [],
            loadedTabs: controller.tabs.count)
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
        _ = try dragPaneDivider(index, through: [fraction], besides: page)
    }

    func dragPaneDivider(_ index: Int, through fractions: [Double], besides page: any E2EPage) throws -> [[Double]] {
        try adapter.requireActive(token, "drag a pane divider")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let container = try Self.paneContainer(of: page)
        let views = container.subviews
        guard let window = container.window, views.count > index + 1, !fractions.isEmpty else {
            throw E2EError("the window shows no divider \(index) (panes=\(views.count))")
        }
        // Panes shown without a sidebar split (a test's `showPanes`) have no saved widths to read.
        let graph = controller.store.graph
        let splitID = graph.activeTabID.flatMap(graph.splitID(containing:))
        // The press lands on the divider's middle; each step moves the pointer so the divider's leading edge sits at
        // `fraction` of the length, which is where the panes before it end.
        let sideBySide = container.isVertical
        let thickness = container.dividerThickness
        let before = views[index].frame
        let length = sideBySide ? container.bounds.width : container.bounds.height
        let across = sideBySide ? container.bounds.midY : container.bounds.midX
        func point(at position: CGFloat) -> NSPoint {
            let along = position + thickness / 2
            return container.convert(sideBySide ? NSPoint(x: along, y: across) : NSPoint(x: across, y: along), to: nil)
        }
        func event(_ type: NSEvent.EventType, at position: CGFloat) throws -> NSEvent {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point(at: position), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw E2EError("cannot make a mouse event") }
            return event
        }
        let start = sideBySide ? before.maxX : before.maxY
        let positions = fractions.map { (length * CGFloat($0)).rounded() }
        let down = try event(.leftMouseDown, at: start)
        let moves = try positions.map { try event(.leftMouseDragged, at: $0) }
        let up = try event(.leftMouseUp, at: positions[positions.count - 1])

        // The saved widths each time the divider moves, read while the drag is still under way.
        let samples = E2EDividerDragSamples()
        let observer = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: container, queue: nil
        ) { note in
            guard note.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
            MainActor.assumeIsolated {
                samples.saved.append(splitID.map { controller.store.graph.splitWidthFractions($0) } ?? [])
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // The moves and the release wait in the event queue before the press is handled, as real ones do, so the
        // split view's tracking loop, run inside its mouseDown, finds them and returns at the release.
        for move in moves { NSApp.postEvent(move, atStart: false) }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        // Anything the press left in the queue never reached a tracking loop: it is taken out, not sent on.
        var left = 0
        while let queued = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast, inMode: .default, dequeue: true)
        {
            guard queued.windowNumber == window.windowNumber else {
                NSApp.postEvent(queued, atStart: true)
                break
            }
            left += 1
        }
        guard left == 0 else { throw E2EError("the press missed divider \(index): \(left) events were not tracked") }
        return samples.saved
    }

    func chooseStackedSplit(top: Bool, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose a stacked split")
        try adapter.chooseMenuItem(path: ["View", top ? "Add Top Split" : "Add Bottom Split"], in: page)
    }

    func splitMenuItemsEnabled(in page: any E2EPage) throws -> [String: Bool] {
        try adapter.requireActive(token, "read the split menu items")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(SplitViewFeature.self),
            let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu
        else { throw E2EError("the app has no View menu or split view feature") }
        var result: [String: Bool] = [:]
        for title in ["Add Split View", "Add Top Split", "Add Bottom Split"] {
            guard let item = view.items.first(where: { $0.title == title }) else {
                throw E2EError("View has no \(title)")
            }
            result[title] = feature.validateMenuItem(item)
        }
        return result
    }

    func paneOverlays(besides page: any E2EPage) throws -> E2EPaneOverlays {
        try adapter.requireActive(token, "read the pane overlays")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let window = controller.window else { throw E2EError("the page has no window") }
        controller.pageArea.layoutSubtreeIfNeeded()
        let findBar = controller.e2eFindBar
        let sheet = controller.feature(PageDialogsFeature.self)?.sheet?.alert.window
        let attached = sheet.flatMap { $0.sheetParent === window ? $0 : nil }
        let prompts = window.childWindows?.compactMap { $0 as? PermissionPromptPanel } ?? []
        return E2EPaneOverlays(
            panes: controller.paneViews.map { $0.convert($0.bounds, to: nil) },
            findBar: findBar.isHidden ? nil : findBar.convert(findBar.bounds, to: nil),
            sheet: attached.map { window.convertFromScreen($0.frame) },
            prompts: prompts.filter(\.isVisible).map { window.convertFromScreen($0.frame) },
            windowOffScreen: !NSScreen.screens.contains { $0.frame.intersects(window.frame) })
    }

    /// The split view holding the panes of `page`'s window.
    private static func paneContainer(of page: any E2EPage) throws -> PaneContainer {
        let views = try E2EAppAdapter.tabPage(page).controller.paneViews
        guard let container = views.first?.superview as? PaneContainer, views.count > 1 else {
            throw E2EError("the window shows no split (panes=\(views.count))")
        }
        return container
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

/// The saved split widths read on each step of a divider drag.
@MainActor
final class E2EDividerDragSamples {
    var saved: [[Double]] = []
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
