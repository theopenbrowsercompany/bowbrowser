import AppKit
import BowCore

/// Something about the sidebar the person has to know: the app's sidebar cannot be opened, was set aside, or a
/// window cannot run. Thrown when a window cannot open, and shown as an alert.
struct SidebarNotice: Error, Equatable, CustomStringConvertible {
    enum Kind: String {
        /// The sidebar file can be neither read nor set aside, or the data folder cannot be created.
        case cannotOpen
        /// The sidebar file was written by a newer Bow, which this build leaves alone.
        case newerFile
        /// The sidebar file could not be read, so it was moved aside and an empty sidebar started.
        case setAside
        /// A Space's profile has no engine profile, so its tabs cannot open.
        case missingProfile
        /// A window's own sidebar (one on an explicit profile) cannot be created.
        case windowSidebar
    }

    var kind: Kind
    /// The alert's title.
    var message: String
    /// The alert's text: what happened, where the file is and what the person can do.
    var detail: String

    var description: String { "\(message) \(detail)" }

    /// Whether the window it is about cannot open (the alert is critical).
    var stopsWindow: Bool { kind == .cannotOpen || kind == .newerFile || kind == .windowSidebar }
}

/// The sidebar stores windows run on, and the engine profile behind each Space's profile ID.
///
/// The app's own sidebar is one file, `Sidebar.json` in the data directory, opened on first use and saved after every
/// change (and again when the app stops, for a write that failed). A window opened on an explicit engine profile (an
/// e2e window, a smoke run) gets a sidebar of its own instead, in a temporary folder, with one Space on that profile,
/// so it never adds tabs to the person's sidebar.
///
/// A window never falls back to a temporary sidebar when the app's sidebar cannot be opened: `main()` throws a notice
/// every time it is asked, and the caller shows it instead of opening the window.
@MainActor
final class SidebarStores: AppFeature {
    private let dataDirectory: URL
    private var mainStore: SidebarStore?
    /// Where window sidebars are kept: a folder of this process in `windowFolderParent`.
    private let windowStoreFolder: URL
    /// Shows notices instead of an alert when set (the e2e harness records them, so no alert waits for a click).
    var presentNotice: (@MainActor (SidebarNotice, NSWindow?) -> Void)?

    convenience init(dataDirectory: URL) {
        self.init(dataDirectory: dataDirectory, windowFolderParent: FileManager.default.temporaryDirectory)
    }

    /// Clears the window sidebar folders that stopped processes left in `windowFolderParent` (a crash skips
    /// `saveAll()`), keeping those of running processes.
    init(dataDirectory: URL, windowFolderParent: URL) {
        self.dataDirectory = dataDirectory
        windowStoreFolder = WindowSidebarFolders.folder(
            in: windowFolderParent, processID: ProcessInfo.processInfo.processIdentifier)
        // Off the main thread: the temporary folder can be large. This process's own folder is never stale.
        DispatchQueue.global(qos: .utility).async {
            WindowSidebarFolders.removeStale(in: windowFolderParent)
        }
    }

    /// The app's sidebar, opened from the data directory on first use, with a notice for the person when opening it
    /// had to set the file aside (only on the call that opened it). Throws, every time it is asked, when the data
    /// folder cannot be created or the file can be neither read nor set aside (or was written by a newer Bow): the
    /// store refuses to start rather than overwrite the file, and no window runs on a temporary sidebar instead.
    func main() throws(SidebarNotice) -> (store: SidebarStore, notice: SidebarNotice?) {
        if let mainStore { return (mainStore, nil) }
        let url = SidebarStore.fileURL(inApplicationSupportFolder: dataDirectory)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            throw SidebarNotice(
                kind: .cannotOpen,
                message: "Bow cannot create its data folder",
                detail: """
                    Bow keeps your sidebar in \(dataDirectory.path), which could not be created \
                    (\(error.localizedDescription)). Make sure the folder can be created, then open Bow again.
                    """)
        }
        let store: SidebarStore
        do {
            store = try SidebarStore(fileURL: url)
        } catch SidebarStoreError.fileFromNewerBuild(let version, let readable) {
            throw SidebarNotice(
                kind: .newerFile,
                message: "Your sidebar was saved by a newer version of Bow",
                detail: """
                    \(url.path) is in format \(version), and this version of Bow reads up to format \(readable). \
                    Bow has left it untouched: open it with the newer version of Bow.
                    """)
        } catch {
            throw SidebarNotice(
                kind: .cannotOpen,
                message: "Bow cannot open your sidebar",
                detail: """
                    Bow could not open \(url.path) (\(error)). It has left the file untouched rather than start \
                    over it. Check that the file and its folder can be read and changed and that the disk has room, \
                    then open Bow again.
                    """)
        }
        var notice: SidebarNotice?
        if case .freshAfterSettingAside(let setAside, let reason) = store.openReport.origin {
            notice = SidebarNotice(
                kind: .setAside,
                message: "Bow could not read your sidebar and started a new one",
                detail: """
                    The old file was moved, untouched, to \(setAside.path) (\(reason)). To try it again, quit Bow \
                    and rename it back to \(SidebarStore.fileName) in the same folder.
                    """)
        }
        mainStore = store
        return (store, notice)
    }

    /// A new, empty sidebar for one window, whose only Space shows `profile`.
    func makeWindowStore(profile: SidebarProfileID) throws(SidebarNotice) -> SidebarStore {
        let url = windowStoreFolder.appendingPathComponent("\(UUID().uuidString).json")
        do {
            try FileManager.default.createDirectory(at: windowStoreFolder, withIntermediateDirectories: true)
            return try Self.store(at: url, profile: profile)
        } catch {
            throw SidebarNotice(
                kind: .windowSidebar,
                message: "Bow cannot open the window",
                detail: "Its sidebar could not be created in \(windowStoreFolder.path) (\(error)).")
        }
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

    /// The notice for a Space on `profile`, which the engine does not have.
    static func missingProfileNotice(_ profile: SidebarProfileID, in graph: SidebarGraph) -> SidebarNotice {
        let space = graph.spaces.first { $0.profileID == profile }?.title ?? "this Space"
        return SidebarNotice(
            kind: .missingProfile,
            message: "This Space's profile is not available",
            detail: """
                The Space “\(space)” uses the profile “\(profile.rawValue)”, which this Bow does not have, so its \
                tabs cannot open. Switch to another Space to keep browsing.
                """)
    }

    /// Shows `notice` as an alert: a sheet on `window` when it is on screen, or else one of its own. It is also
    /// written to standard error. `presentNotice` takes it instead when set.
    func present(_ notice: SidebarNotice, in window: NSWindow?) {
        FileHandle.standardError.write(Data("bow: \(notice)\n".utf8))
        if let presentNotice {
            presentNotice(notice, window)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = notice.stopsWindow ? .critical : .warning
        alert.messageText = notice.message
        alert.informativeText = notice.detail
        if let window {
            // A window that is about to show gets its sheet once it does.
            if window.isVisible {
                alert.beginSheetModal(for: window)
            } else {
                DispatchQueue.main.async { [weak window] in
                    if let window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
                }
            }
        } else {
            alert.runModal()
        }
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
