import AppKit
import BowCore
import UniformTypeIdentifiers

/// What the Arc import wizard needs from the app: the file and folder pickers, reading the sidebar file or the User
/// Data folder the person chose, registering the profiles that imported Spaces use, and the history stores imported
/// visits go into. One wizard runs at a time across every window.
///
/// Nothing here reads Arc's data until the person picks a file or folder: the pickers only start in the folders where
/// Arc keeps its data, as a suggestion, and the app never opens or lists those folders itself. From a User Data
/// folder only `Local State`, each profile's `Bookmarks` and a copy of its `History` are read (`ChromiumUserData`).
@MainActor
final class ArcImportFeature: AppFeature {
    /// The wizard on screen, if any. Held here until its sheet ends, which is also what lets a second one not start.
    private(set) var activeWizard: ArcImportWizard?

    #if BOW_E2E  // E2E seam: e2e picks the file through this closure and never shows an open panel.
        /// Answers the file picker. An e2e run has no picker: with no closure set the answer is "cancelled".
        var e2eChooseFile: (@MainActor () -> URL?)?
        /// How many times the picker was asked, so a test sees that the wizard asked for the file.
        var e2eFileRequests = 0
        /// Answers the folder picker of the history step, as `e2eChooseFile` does for the file.
        var e2eChooseFolder: (@MainActor () -> URL?)?
        /// How many times the folder picker was asked.
        var e2eFolderRequests = 0
        /// Every file the last history read touched, so a test sees exactly which files were read.
        var e2eLastFileLog: ChromiumFileLog?
    #endif

    private var terminateObserver: (any NSObjectProtocol)?

    init(dataDirectory: URL) {
        // A copy of History is deleted as soon as it is read. One left behind by a quit or crash mid-read is
        // deleted here, at the next launch, and the app deletes the folder again when it quits.
        Self.removeTemporaryFolder()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            Self.removeTemporaryFolder()
        }
    }

    /// Where the history step copies History files to read them, apart from everything else in the temporary folder.
    nonisolated static var temporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bow-arc-import", isDirectory: true)
    }

    nonisolated private static func removeTemporaryFolder() {
        try? FileManager.default.removeItem(at: temporaryFolder)
    }

    /// Where Arc keeps its profiles (its Chromium User Data folder), offered as the folder picker's starting folder
    /// only. Never read or listed by the app.
    static var suggestedUserDataFolder: URL {
        suggestedFolder.appendingPathComponent("User Data", isDirectory: true)
    }

    /// Where Arc keeps its sidebar file, offered as the picker's starting folder only. Never read by the app.
    static var suggestedFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return (support ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Arc", isDirectory: true)
    }

    /// Opens the wizard as a sheet on `window` unless one is already open. Returns whether it opened.
    @discardableResult
    func openWizard(in controller: BrowserWindowController) -> Bool {
        guard activeWizard == nil, let window = controller.window, window.attachedSheet == nil else { return false }
        let wizard = ArcImportWizard(controller: controller, service: self)
        activeWizard = wizard
        wizard.begin(on: window)
        return true
    }

    /// Asks the person for a file. Nil when they cancel.
    func chooseFile(for window: NSWindow?) async -> URL? {
        #if BOW_E2E  // E2E seam
            e2eFileRequests += 1
            return e2eChooseFile?()
        #else
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]
            panel.message = "Choose Arc's sidebar file (StorableSidebar.json)."
            panel.prompt = "Choose"
            panel.directoryURL = Self.suggestedFolder
            let response: NSApplication.ModalResponse
            if let window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            return response == .OK ? panel.url : nil
        #endif
    }

    /// Asks the person for Arc's User Data folder. Nil when they cancel.
    func chooseUserDataFolder(for window: NSWindow?) async -> URL? {
        #if BOW_E2E  // E2E seam
            e2eFolderRequests += 1
            return e2eChooseFolder?()
        #else
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose Arc's User Data folder. Bow reads only Local State, Bookmarks and History from it."
            panel.prompt = "Choose"
            panel.directoryURL = Self.suggestedUserDataFolder
            let response: NSApplication.ModalResponse
            if let window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            return response == .OK ? panel.url : nil
        #endif
    }

    /// Reads the profiles, bookmarks and History copies of the User Data folder at `url` off the main thread,
    /// recording every file in `log`. Cancelling the calling task stops the read before its next profile; the copy
    /// of a History file being read is deleted either way.
    nonisolated static func readUserData(_ url: URL, log: ChromiumFileLog) async throws -> [ChromiumProfileData] {
        let read = Task.detached(priority: .userInitiated) {
            try ChromiumUserData.read(url, temporaryFolder: temporaryFolder, log: log) { Task.isCancelled }
        }
        return try await withTaskCancellationHandler {
            try await read.value
        } onCancel: {
            read.cancel()
        }
    }

    /// Adds each list of visits to its history store off the main thread, one transaction per list, and returns
    /// what each added (or why it failed), in order.
    nonisolated static func importVisits(_ jobs: [(store: HistoryStore, visits: [HistoryImportVisit])]) async
        -> [Result<HistoryImportRecord, any Error>]
    {
        await Task.detached(priority: .userInitiated) {
            jobs.map { job in Result { try job.store.importVisits(job.visits) } }
        }.value
    }

    /// Whether Bow has the profile `id`: the default one, or one the profile registry lists.
    func hasProfile(_ id: SidebarProfileID, in features: AppFeatureSet) -> Bool {
        id == .default || features.require(ProfileRegistryStore.self).registry?.profile(for: id) != nil
    }

    /// A name for the profile `id` in the wizard.
    func profileName(_ id: SidebarProfileID, in features: AppFeatureSet) -> String {
        if id == .default { return "Default" }
        return features.require(ProfileRegistryStore.self).registry?.profile(for: id)?.name ?? id.rawValue
    }

    /// The history store of Bow profile `id`, through the engine profile behind it (made now when the registry has
    /// the profile and the engine does not yet). Nil when the profile or its history cannot be opened.
    func historyStore(for id: SidebarProfileID, in features: AppFeatureSet) -> HistoryStore? {
        guard let engine = (NSApp.delegate as? AppDelegate)?.engine,
            let profile = features.require(ProfileRegistryStore.self).engineProfile(for: id, engine: engine)
        else { return nil }
        return features.require(HistoryStores.self).store(
            for: profile.profileID, isPersistent: { profile.isPersistent })
    }

    /// Reads and parses the file at `url` off the main thread. Reading never changes the file.
    nonisolated static func read(_ url: URL) async throws -> ArcImportResult {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try ArcImporter.parse(data)
        }.value
    }

    /// The text for a failure to read or parse the file, for the wizard to show.
    static func message(for error: any Error) -> String {
        switch error {
        case ArcImportError.invalidJSON:
            "This file is not JSON, so it cannot be Arc's sidebar file."
        case ArcImportError.notAnArcSidebar:
            "This file is not an Arc sidebar file. Choose StorableSidebar.json."
        default:
            "The file could not be read (\(error.localizedDescription))."
        }
    }

    /// Registers the profile of each Space the import created, so its tabs can open. A profile Bow already has is
    /// kept as it is. Throws when the profiles file cannot be written.
    func registerProfiles(of applied: ArcImportApplied, in store: SidebarStore, using profiles: ProfileRegistryStore)
        throws
    {
        guard let registry = profiles.registry else {
            throw ProfileRegistryError.unreadableFileNotSetAside("no registry")
        }
        let graph = store.graph
        for id in applied.spaceIDs {
            guard let space = graph.space(id), space.profileID != .default else { continue }
            try registry.adopt(id: space.profileID, name: space.title)
        }
    }

    /// Called by the wizard when its sheet closes.
    func didEnd(_ wizard: ArcImportWizard) {
        if activeWizard === wizard { activeWizard = nil }
    }
}
