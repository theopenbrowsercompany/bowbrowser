import AppKit
import BowCore

// The reopen area of the adapter: E2EReopenApp over the app delegate's applicationShouldHandleReopen, the method
// AppKit calls when the Dock icon is clicked. The window it opens is made off screen through the delegate's seam.

extension E2EAppAdapter {
    func seedAppSidebar(url: URL) throws {
        guard delegate.openBrowserWindows.isEmpty else {
            throw E2EError("a window is open; the app sidebar is seeded before one")
        }
        guard let profile = delegate.engine.profile(id: .default) else {
            throw E2EError("the engine has no default profile")
        }
        let store: SidebarStore
        do {
            store = try delegate.appFeatures.require(SidebarStores.self).main().store
            let profileID = SidebarStores.sidebarProfileID(of: profile.profileID)
            let fresh = store.graph.spaces.map(\.id)
            var ids: [SidebarSpaceID] = []
            for title in ["Reopen A", "Reopen B"] {
                let id = try store.createSpace(title: title, profileID: profileID, activate: false)
                ids.append(id)
                guard let space = store.graph.space(id) else { throw E2EError("Space \(title) was not created") }
                try store.apply([
                    .insert(.tab(url: url.absoluteString, title: title), parent: space.unpinnedContainerID)
                ])
            }
            for id in fresh { _ = try store.deleteSpace(id) }
            try store.switchToSpace(ids[0])
        } catch let error as E2EError {
            throw error
        } catch {
            throw E2EError("cannot seed the app's sidebar: \(error)")
        }
    }

    func reopenApp(token: Int) async throws -> E2EReopened {
        let delegate = delegate
        var opened: BrowserWindowController?
        // The delegate's own window opening, in an off-screen window; it is tracked and ordered in below.
        delegate.e2eOpenWindow = { open in
            let controller = try open(Self.makeWindow())
            opened = controller
            return controller
        }
        defer { delegate.e2eOpenWindow = nil }
        // The same method AppKit calls for a click on the Dock icon; no window of ours is on screen.
        let leftToSystem = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        var page: E2ETabPage?
        var title: String?
        if let opened {
            page = try await show(opened, token: token)
            title = opened.store.graph.activeSpaceID.flatMap { opened.store.graph.space($0)?.title }
        }
        return E2EReopened(
            leftToSystem: leftToSystem, page: page, spaceTitle: title, windowCount: delegate.openBrowserWindows.count)
    }

    func showSpace(titled title: String, in page: any E2EPage) throws {
        let controller = try Self.tabPage(page).controller
        guard let space = controller.store.graph.spaces.first(where: { $0.title == title }) else {
            throw E2EError("the window has no Space titled \(title)")
        }
        guard controller.changeSidebar({ try $0.switchToSpace(space.id) }) else {
            throw E2EError("the window did not show Space \(title)")
        }
    }
}

extension E2ETestApp: E2EReopenApp {
    func seedAppSidebar(url: URL) throws {
        try adapter.requireActive(token, "seed the app's sidebar")
        try adapter.seedAppSidebar(url: url)
    }

    func appWindowCount() throws -> Int {
        try adapter.requireActive(token, "count the app's windows")
        return adapter.delegate.openBrowserWindows.count
    }

    func reopenApp() async throws -> E2EReopened {
        try adapter.requireActive(token, "reopen the app")
        return try await adapter.reopenApp(token: token)
    }

    func showSpace(titled title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "show a Space")
        try adapter.showSpace(titled: title, in: page)
    }
}
