import BowCore
import Foundation

/// Each profile's remembered permission answers, created on first use and shared by the profile's windows.
@MainActor
final class SitePermissionStores: AppFeature {
    private let dataDirectory: URL
    private var stores: [ProfileID: SitePermissionStore] = [:]

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    /// The permission store of `profile`: a file in the data directory's `Permissions` folder for a persistent
    /// profile, memory only for an in-memory one.
    func store(for profile: any EngineProfile) -> SitePermissionStore {
        if let store = stores[profile.profileID] { return store }
        let file = dataDirectory.appendingPathComponent("Permissions", isDirectory: true)
            .appendingPathComponent(profile.profileID.rawValue + ".json")
        let store = SitePermissionStore(fileURL: profile.isPersistent ? file : nil)
        stores[profile.profileID] = store
        return store
    }
}
