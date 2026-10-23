import AppKit
import BowCore

// The profiles area of the adapter: E2EProfilesApp over the window's shown tab, the app's ProfileRegistryStore and
// the app's child processes.

extension E2EAppAdapter {
    func shownPage(besides page: any E2EPage, token: Int) throws -> (any E2EPage)? {
        let given = try Self.tabPage(page)
        let controller = given.controller
        guard let tab = controller.selectedTab else { return nil }
        if tab === given.tab { return given }
        return track(tab, in: controller, token: token)
    }

    func registeredProfiles() -> [String] {
        let profiles = delegate.appFeatures.require(ProfileRegistryStore.self).registry?.profiles ?? []
        return profiles.map { "\($0.id.rawValue):\($0.name)" }
    }

    /// Counts the app's child processes started as Chromium renderers, read from `ps`.
    func rendererProcessCount() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let own = ProcessInfo.processInfo.processIdentifier
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            return parts.count == 2 && Int32(parts[0]) == own && parts[1].contains("--type=renderer")
        }.count
    }
}

extension E2EAppAdapter {
    /// Follows `path` through `items` and its submenus to the last item, which must be enabled.
    static func e2eMenuItem(at path: [String], in items: [NSMenuItem], menu: String) throws -> NSMenuItem {
        var items = items
        var chosen: NSMenuItem?
        for title in path {
            guard let item = items.first(where: { $0.title == title }) else {
                throw E2EError("the \(menu) has no item \"\(path.joined(separator: "/"))\": \(items.map(\.title))")
            }
            chosen = item
            items = item.submenu?.items ?? []
        }
        guard let item = chosen, item.isEnabled else {
            throw E2EError("the \(menu)'s \"\(path.joined(separator: "/"))\" is disabled")
        }
        return item
    }

    func chooseTabMenuItem(path: [String], of page: any E2EPage) throws {
        let item = try Self.e2eMenuItem(at: path, in: try tabMenuItems(of: page), menu: "tab menu")
        guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item) else {
            throw E2EError("the tab menu's \"\(path.joined(separator: "/"))\" did nothing")
        }
    }

    func spaceSubmenuTitles(_ path: [String], in page: any E2EPage) throws -> [String] {
        let item = try Self.e2eMenuItem(at: path, in: try spaceMenu(in: page).items, menu: "Space menu")
        return (item.submenu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title + ($0.isEnabled ? "" : "!") }
    }

    func dropOnFavoritesGrid(item id: String, in page: any E2EPage) throws -> Bool {
        let grid = try Self.favoritesGrid(of: page)
        return grid.drop(SidebarItemID(id), at: grid.tiles.count)
    }

    func createRegisteredProfile(named name: String) throws -> String {
        try delegate.appFeatures.require(ProfileRegistryStore.self).createProfile(named: name).id.rawValue
    }

    func deleteMarkedProfileFolders() -> [String] {
        delegate.appFeatures.require(ProfileRegistryStore.self)
            .deleteMarkedFolders(spaceProfiles: ProfileMoves.spaceProfiles())
            .map { "\($0.folderName):\($0.outcome)" }
    }
}

extension E2ETestApp: E2EProfilesApp {
    func chooseTabMenuItem(path: [String], of page: any E2EPage) throws {
        try adapter.requireActive(token, "choose \(path.joined(separator: " > ")) in a tab's menu")
        try adapter.chooseTabMenuItem(path: path, of: page)
    }

    func sidebarItemID(of page: any E2EPage) throws -> String {
        try E2EAppAdapter.sidebarItem(of: try E2EAppAdapter.tabPage(page)).rawValue
    }

    func spaceSubmenuTitles(_ path: [String], in page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read the Space menu")
        return try adapter.spaceSubmenuTitles(path, in: page)
    }

    func dropOnFavoritesGrid(item id: String, in page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "drop on the Favorites grid")
        return try adapter.dropOnFavoritesGrid(item: id, in: page)
    }

    func createRegisteredProfile(named name: String) throws -> String {
        try adapter.requireActive(token, "create a profile")
        return try adapter.createRegisteredProfile(named: name)
    }

    func deleteMarkedProfileFolders() throws -> [String] {
        try adapter.requireActive(token, "delete the marked profile folders")
        return adapter.deleteMarkedProfileFolders()
    }

    func shownPage(besides page: any E2EPage) throws -> (any E2EPage)? {
        try adapter.requireActive(token, "read the shown page")
        return try adapter.shownPage(besides: page, token: token)
    }

    func registeredProfiles() throws -> [String] {
        try adapter.requireActive(token, "read the registered profiles")
        return adapter.registeredProfiles()
    }

    func rendererProcessCount() throws -> Int {
        try adapter.requireActive(token, "count renderer processes")
        return try adapter.rendererProcessCount()
    }
}
