import AppKit
import BowCore

// The tabs area of the adapter: E2ETabsApp over the window controller and the engine tab's unload.

extension E2ETestApp: E2ETabsApp {
    func unloadTab(_ page: any E2EPage) async throws -> E2EUnloadedTab {
        try adapter.requireActive(token, "unload a tab")
        return try await adapter.unloadTab(page, token: token)
    }
}

extension E2EAppAdapter {
    func unloadTab(_ page: any E2EPage, token: Int) async throws -> E2EUnloadedTab {
        let page = try Self.tabPage(page)
        let controller = page.controller
        let tab = page.tab
        guard let id = controller.modelID(of: tab), let item = controller.sidebarItemID(for: id) else {
            throw E2EError("tab \(tab.tabID) is not in its window")
        }
        // Hears the tab's last event right after the window and the adapter's own handler have.
        let heard = HeardEvent()
        let previous = controller.onTabEvent
        controller.onTabEvent = { other, event in
            previous?(other, event)
            guard other === tab else { return }
            if event == .unloaded { heard.hear("unloaded") } else if event == .closed { heard.hear("closed") }
        }
        defer { controller.onTabEvent = previous }
        let unloaded = await tab.unload()
        // The engine reports an unload on a later main thread task than its answer; a refusal reports nothing.
        let event = unloaded || tab.isClosed ? try await heard.wait() : "none"
        try requireActive(token, "read an unloaded tab")
        let sidebar = controller.e2eSidebar
        let rowTitle = sidebar.row(for: item).flatMap {
            (sidebar.outlineView.view(atColumn: 0, row: $0, makeIfNecessary: true) as? TabSidebarRow)?
                .titleField.stringValue
        }
        return E2EUnloadedTab(
            unloaded: unloaded,
            event: event,
            windowHoldsPage: controller.engineTab(for: id) === tab,
            rowTitle: controller.store.graph[item] == nil ? nil : rowTitle
        ) { [unowned self] in
            try requireActive(token, "choose an unloaded tab's row")
            guard let row = sidebar.row(for: item) else { throw E2EError("the unloaded tab has no sidebar row") }
            // What the outline's click action does with the clicked row.
            sidebar.clickRow(row)
            guard let shown = controller.selectedTab, controller.engineTab(for: id) === shown else { return nil }
            // Tracked before the engine reports anything about the new page, which it does on later main thread
            // tasks.
            return shown === tab ? page : track(shown, in: controller, token: token)
        }
    }
}

/// One event a test step waits for, heard on the main thread. A wait the step's timeout cancels ends at once.
@MainActor
private final class HeardEvent {
    private var event: String?
    private var waiter: CheckedContinuation<String, Error>?

    func hear(_ event: String) {
        guard self.event == nil else { return }
        self.event = event
        waiter?.resume(returning: event)
        waiter = nil
    }

    func wait() async throws -> String {
        if let event { return event }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func cancel() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
