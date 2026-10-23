import BowCore
import Foundation

// The history area of the adapter: E2EHistoryApp over the app's HistoryStores.

extension E2EAppAdapter {
    private func historyStores(of page: any E2EPage) throws -> (HistoryStores, ProfileID) {
        let page = try Self.tabPage(page)
        return (page.controller.appFeatures.require(HistoryStores.self), page.tab.profileID)
    }

    func historyEntries(of page: any E2EPage) throws -> [E2EHistoryEntry] {
        let (stores, profileID) = try historyStores(of: page)
        guard let store = stores.existingStore(for: profileID) else { return [] }
        return try Self.oldestFirst(store)
    }

    func historyFile(of page: any E2EPage) throws -> URL? {
        let (stores, profileID) = try historyStores(of: page)
        return stores.existingStore(for: profileID)?.fileURL
    }

    /// Opens `file` with a store of its own (another connection to the same file), the way a relaunch would.
    func historyEntries(inFile file: URL) throws -> [E2EHistoryEntry] {
        let folder = file.deletingLastPathComponent()
        guard let profileID = Self.profileID(ofHistoryFolder: folder) else {
            throw E2EError("\(folder.lastPathComponent) is not a history folder")
        }
        let store = try HistoryStore(
            profileID: profileID, isPersistent: true, directory: folder.deletingLastPathComponent())
        return try Self.oldestFirst(store)
    }

    func hasHistoryFolder(of page: any E2EPage) throws -> Bool {
        let (stores, profileID) = try historyStores(of: page)
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: stores.historyDirectory, includingPropertiesForKeys: nil)) ?? []
        return folders.contains { Self.profileID(ofHistoryFolder: $0) == profileID }
    }

    private static func oldestFirst(_ store: HistoryStore) throws -> [E2EHistoryEntry] {
        try store.recent(limit: 1000).reversed().map {
            E2EHistoryEntry(url: $0.url, title: $0.title, visitCount: $0.visitCount)
        }
    }

    /// Reverses the folder name `p<hex of the profile ID>` that `HistoryStore` gives a profile.
    private static func profileID(ofHistoryFolder folder: URL) -> ProfileID? {
        let name = folder.lastPathComponent
        guard name.hasPrefix("p") else { return nil }
        let hex = Array(name.dropFirst())
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return ProfileID(String(decoding: bytes, as: UTF8.self))
    }
}

extension E2ETestApp: E2EHistoryApp {
    func historyEntries(of page: any E2EPage) throws -> [E2EHistoryEntry] {
        try adapter.historyEntries(of: page)
    }

    func historyFile(of page: any E2EPage) throws -> URL? {
        try adapter.historyFile(of: page)
    }

    func historyEntries(inFile file: URL) throws -> [E2EHistoryEntry] {
        try adapter.historyEntries(inFile: file)
    }

    func hasHistoryFolder(of page: any E2EPage) throws -> Bool {
        try adapter.hasHistoryFolder(of: page)
    }
}
