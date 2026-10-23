import AppKit
import BowCore

// The panes area of the adapter: E2EPanesApp over the window controller's pane API.

extension E2ETestApp: E2EPanesApp {
    func showPanes(_ pages: [any E2EPage], focused: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "show panes")
        let tabPages = try pages.map(E2EAppAdapter.tabPage)
        let focused = try E2EAppAdapter.tabPage(focused)
        guard let controller = tabPages.first?.controller, tabPages.allSatisfy({ $0.controller === controller })
        else { throw E2EError("the panes' pages are not in one window") }
        return controller.showPanes(tabPages.map(\.tab), focused: focused.tab)
    }

    func focusPane(at index: Int, besides page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "focus a pane")
        return try E2EAppAdapter.tabPage(page).controller.focusPane(at: index)
    }

    func clickPane(at index: Int, besides page: any E2EPage) throws {
        try adapter.requireActive(token, "click a pane")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let views = controller.paneViews
        guard let window = controller.window, views.indices.contains(index) else {
            throw E2EError("the window has no pane \(index) (panes=\(views.count))")
        }
        let view = views[index]
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)
            else { throw E2EError("cannot make a mouse event") }
            return event
        }
        let down = try event(.leftMouseDown)
        let up = try event(.leftMouseUp)
        // The release waits in the event queue before the press is handled, as a real one does, so a view that tracks
        // the press until the release finds it.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            guard queued.windowNumber == window.windowNumber else {
                NSApp.postEvent(queued, atStart: true)
                return
            }
            window.sendEvent(queued)
        }
    }

    func addPageOverlay(besides page: any E2EPage) throws -> Int {
        try adapter.requireActive(token, "add a page overlay")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let overlay = E2EPageOverlayView()
        controller.addPageOverlay(overlay)
        return overlay.tag
    }

    func panes(besides page: any E2EPage) throws -> E2EPaneState {
        let controller = try E2EAppAdapter.tabPage(page).controller
        let pageArea = controller.pageArea
        pageArea.layoutSubtreeIfNeeded()
        let tabs = controller.tabs
        let title = { (tab: any EngineTab) in
            controller.tabList.tabs.first { controller.engineTab(for: $0.id) === tab }?.title ?? "?"
        }
        let views = controller.paneViews
        let focused = controller.focusedPane
        let responder = controller.window?.firstResponder as? NSView
        return E2EPaneState(
            titles: views.map { view in tabs.first { view.isShowing($0) }.map(title) ?? "-" },
            focusedIndex: views.firstIndex { $0 === focused } ?? -1,
            selectedTitle: controller.selectedTab.map(title),
            activeTitle: controller.tabList.activeTab?.title,
            frames: views.map { $0.convert($0.bounds, to: pageArea) },
            pageSize: pageArea.bounds.size,
            outlined: views.indices.filter { (views[$0].layer?.borderWidth ?? 0) > 0 },
            keyboardInFocused: responder.map { $0 !== focused && $0.isDescendant(of: focused) } ?? false,
            frontmostTag: pageArea.subviews.last?.tag ?? 0)
    }
}

/// A plain view a test places over the page area, told apart by its tag.
final class E2EPageOverlayView: NSView {
    override var tag: Int { 4242 }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
