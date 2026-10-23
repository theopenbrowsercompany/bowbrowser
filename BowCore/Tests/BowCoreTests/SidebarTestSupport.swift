import Foundation

@testable import BowCore

/// Runs `body` with a new empty folder that is deleted afterwards.
func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SidebarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        // Restore write permission a test may have removed, so the folder can be deleted.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }
    try body(folder)
}

extension SidebarGraph {
    var firstSpace: SidebarSpace { spaces[0] }
    var pinnedID: SidebarItemID { spaces[0].pinnedContainerID }
    var unpinnedID: SidebarItemID { spaces[0].unpinnedContainerID }

    /// A fresh graph with deterministic container IDs.
    static func sample() -> SidebarGraph {
        let favorites = SidebarItem(id: "favorites", data: .container(SidebarContainer(kind: .favorites)))
        let pinned = SidebarItem(id: "pinned", data: .container(SidebarContainer(kind: .pinned)))
        let unpinned = SidebarItem(id: "unpinned", data: .container(SidebarContainer(kind: .unpinned)))
        let space = SidebarSpace(
            id: "home", title: "Home", pinnedContainerID: "pinned", unpinnedContainerID: "unpinned")
        return SidebarGraph(
            items: [favorites.id: favorites, pinned.id: pinned, unpinned.id: unpinned],
            spaces: [space],
            favoritesContainerIDs: [.default: "favorites"],
            activeSpaceID: "home")
    }

    /// Applies mutations, failing the test on error.
    func applying(_ mutations: [SidebarMutation]) throws -> SidebarGraph {
        var graph = self
        for mutation in mutations { try graph.apply(mutation) }
        return graph
    }

    /// A sample with twelve items: favorites, a pinned folder with a nested folder and a split, and unpinned tabs.
    static func twelveItems() throws -> SidebarGraph {
        try sample().applying([
            .insert(.tab(id: "fav-mail", url: "https://mail.example.com", title: "Mail"), parent: "favorites"),
            .insert(.tab(id: "fav-cal", url: "https://cal.example.com", title: "Calendar"), parent: "favorites"),
            .insert(.folder(id: "work", title: "Work"), parent: "pinned"),
            .insert(.tab(id: "docs", url: "https://docs.example.com", title: "Docs"), parent: "work"),
            .insert(.folder(id: "deep", title: "Deep"), parent: "work"),
            .insert(.tab(id: "deep-tab", url: "https://deep.example.com", title: "Deep"), parent: "deep"),
            .insert(.split(id: "split", orientation: .vertical), parent: "pinned"),
            .insert(.tab(id: "left", url: "https://left.example.com", title: "Left"), parent: "split"),
            .insert(.tab(id: "right", url: "https://right.example.com", title: "Right"), parent: "split"),
            .insert(
                .tab(id: "renamed", url: "https://example.com/a", title: "A", customTitle: "My page"), parent: "pinned"),
            .insert(.tab(id: "news", url: "https://news.example.com", title: "News"), parent: "unpinned"),
            .insert(.tab(id: "search", url: "https://search.example.com/?q=a b", title: "Search"), parent: "unpinned"),
            .setActiveTab("news"),
        ])
    }
}
