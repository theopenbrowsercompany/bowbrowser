import BowCore
import Foundation

/// The sidebar stores windows run on, and the engine profile behind each Space's profile ID.
///
/// The app's own sidebar is one file, `Sidebar.json` in the data directory, opened on first use and saved after every
/// change (and again when the app stops, for a write that failed). A window opened on an explicit engine profile (an
/// e2e window, a smoke run) gets a sidebar of its own instead, in a temporary folder, with one Space on that profile,
/// so it never adds tabs to the person's sidebar.
@MainActor
final class SidebarStores: AppFeature {
    private let dataDirectory: URL
    private var mainStore: SidebarStore?
    /// True once opening the app's sidebar failed, so it is not tried (and reported) again for every window.
    private var mainStoreFailed = false
    /// Where window sidebars are kept: a folder of this process in the temporary directory.
    private lazy var windowStoreFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("bow-sidebars-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    /// The app's sidebar, opened from the data directory on first use. Nil when the file can be neither read nor set
    /// aside, in which case the store refuses to start rather than overwrite it.
    func main() -> SidebarStore? {
        if let mainStore { return mainStore }
        guard !mainStoreFailed else { return nil }
        mainStoreFailed = true
        let url = SidebarStore.fileURL(inApplicationSupportFolder: dataDirectory)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let store = try SidebarStore(fileURL: url)
            mainStore = store
            mainStoreFailed = false
            return store
        } catch {
            FileHandle.standardError.write(Data("bow: cannot open the sidebar at \(url.path): \(error)\n".utf8))
            return nil
        }
    }

    /// A new, empty sidebar for one window, whose only Space shows `profile`.
    func makeWindowStore(profile: SidebarProfileID) throws -> SidebarStore {
        try FileManager.default.createDirectory(at: windowStoreFolder, withIntermediateDirectories: true)
        let url = windowStoreFolder.appendingPathComponent("\(UUID().uuidString).json")
        return try Self.store(at: url, profile: profile)
    }

    /// Opens the sidebar at `url`; a fresh one (no file yet) gets its only Space on `profile`.
    static func store(at url: URL, profile: SidebarProfileID) throws -> SidebarStore {
        let store = try SidebarStore(fileURL: url)
        if store.openReport.origin != .loaded, let fresh = store.graph.activeSpaceID,
            store.graph.activeSpace?.profileID != profile
        {
            try store.createSpace(title: SidebarGraph.defaultSpaceTitle, profileID: profile)
            try store.deleteSpace(fresh)
        }
        return store
    }

    /// Writes the app's sidebar if a save failed earlier, and removes the window sidebars, which last only as long as
    /// the app runs. The app calls it when it stops.
    func saveAll() {
        do {
            try mainStore?.save()
        } catch {
            FileHandle.standardError.write(Data("bow: saving the sidebar failed: \(error)\n".utf8))
        }
        try? FileManager.default.removeItem(at: windowStoreFolder)
    }

    /// The sidebar profile ID of an engine profile: the engine's default profile is the sidebar's default profile,
    /// any other keeps its engine ID.
    static func sidebarProfileID(of profile: ProfileID) -> SidebarProfileID {
        profile == .default ? .default : SidebarProfileID(profile.rawValue)
    }

    /// The engine profile ID of a sidebar profile ID, the reverse of `sidebarProfileID(of:)`.
    static func engineProfileID(of profile: SidebarProfileID) -> ProfileID {
        profile == .default ? .default : ProfileID(profile.rawValue)
    }
}
