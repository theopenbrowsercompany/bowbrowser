import AppKit
import BowCore

// The store seed area of the adapter: E2EStoreSeedApp over BowCore's SidebarStore and the app delegate's window
// opening. Seeded sidebars are saved in `seedFolder`, one folder per test.

extension E2EAppAdapter {
    func openWindow(seeded seed: E2ESeed, token: Int) async throws -> E2ESeededWindow {
        guard !seed.spaces.isEmpty else { throw E2EError("a seed needs at least one Space") }
        // Spaces and items are named apart (spaceIDs, itemIDs), so a Space and an item may share a name.
        let itemNames = seed.spaces.flatMap { Self.names(in: $0.pinned + $0.today) }
        for (kind, names) in [("Space", seed.spaces.map(\.name)), ("item", itemNames)] {
            if let repeated = Dictionary(grouping: names, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                throw E2EError("the seed names more than one \(kind) \"\(repeated)\"")
            }
        }
        let store: SidebarStore
        do {
            // One folder per test, so a failed test's seeds are easy to find in the kept profile folder.
            let folder = seedFolder.appendingPathComponent(testProfileID, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = try SidebarStore(fileURL: folder.appendingPathComponent("\(UUID().uuidString).json"))
        } catch {
            throw E2EError("cannot create a sidebar to seed: \(error)")
        }
        var spaceIDs: [String: String] = [:]
        var itemIDs: [String: String] = [:]
        // Profiles made for this seed, by ID, so Spaces naming the same new profile share it.
        var newProfiles: [String: any EngineProfile] = [:]
        do {
            // A fresh store starts with one Space on the default profile; the seed's Spaces replace it.
            let fresh = store.graph.spaces.map(\.id)
            for space in seed.spaces {
                let engineProfile: (any EngineProfile)?
                switch space.profile {
                case .new(let profile):
                    engineProfile = try newProfiles[profile.id] ?? self.engineProfile(for: space.profile)
                    newProfiles[profile.id] = engineProfile
                case .test, .appDefault:
                    engineProfile = try self.engineProfile(for: space.profile)
                }
                guard let engineProfile else { throw E2EError("the engine has no profile for Space \(space.name)") }
                let id = try store.createSpace(
                    title: space.name, profileID: SidebarStores.sidebarProfileID(of: engineProfile.profileID),
                    activate: false)
                spaceIDs[space.name] = id.rawValue
                guard let created = store.graph.space(id) else { throw E2EError("Space \(space.name) was not created") }
                try Self.insert(space.pinned, into: created.pinnedContainerID, of: store, recording: &itemIDs)
                try Self.insert(space.today, into: created.unpinnedContainerID, of: store, recording: &itemIDs)
            }
            for id in fresh { _ = try store.deleteSpace(id) }
            let active = seed.activeSpace ?? seed.spaces[0].name
            guard let activeID = spaceIDs[active] else { throw E2EError("the seed has no Space named \(active)") }
            try store.switchToSpace(SidebarSpaceID(activeID))
        } catch let error as E2EError {
            throw error
        } catch {
            throw E2EError("the sidebar store refused the seed: \(error)")
        }
        let delegate = delegate
        let page = try await showWindow(token: token) { window in
            try delegate.openWindow(url: nil, store: store, window: window)
        }
        return E2ESeededWindow(page: page, spaceIDs: spaceIDs, itemIDs: itemIDs)
    }

    private static func names(in items: [E2ESeedItem]) -> [String] {
        items.flatMap { item -> [String] in
            if case .folder(_, _, let children) = item { return [item.name] + names(in: children) }
            return [item.name]
        }
    }

    private static func insert(
        _ items: [E2ESeedItem], into parent: SidebarItemID, of store: SidebarStore,
        recording ids: inout [String: String]
    ) throws {
        for item in items {
            switch item {
            case .tab(let name, let url):
                let tab = SidebarItem.tab(url: url.absoluteString, title: name)
                try store.apply([.insert(tab, parent: parent)])
                ids[name] = tab.id.rawValue
            case .folder(let name, let expanded, let children):
                let folder = SidebarItem.folder(title: name)
                try store.apply([.insert(folder, parent: parent), .setFolderExpanded(folder.id, expanded)])
                ids[name] = folder.id.rawValue
                try insert(children, into: folder.id, of: store, recording: &ids)
            }
        }
    }
}

extension E2ETestApp: E2EStoreSeedApp {
    func openWindow(seeded seed: E2ESeed) async throws -> E2ESeededWindow {
        try adapter.requireActive(token, "open a seeded window")
        return try await adapter.openWindow(seeded: seed, token: token)
    }
}
