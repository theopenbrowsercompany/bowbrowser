import AppKit
import BowCore

// The window edges area of the adapter: E2EWindowEdgesApp over the window controller.

extension E2ETestApp: E2EWindowEdgesApp {
    var windowEdges: E2EWindowEdges {
        E2EWindowEdges(adapter: adapter, token: token) { [adapter, token] action in
            try adapter.requireActive(token, action)
        }
    }
}

extension E2EAppAdapter {
    func windowAndTab(of page: any E2EPage) throws -> (BrowserWindowController, any EngineTab) {
        let page = try Self.tabPage(page)
        return (page.controller, page.tab)
    }

    func page(for tab: any EngineTab, in controller: BrowserWindowController, token: Int) -> any E2EPage {
        track(tab, in: controller, token: token)
    }
}
