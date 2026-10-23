import AppKit
import BowCore
import UniformTypeIdentifiers

/// What the Arc import wizard needs from the app: the file picker, reading and parsing the file the person chose,
/// and registering the profiles that imported Spaces use. One wizard runs at a time across every window.
///
/// Nothing here reads Arc's data until the person picks a file: the picker only starts in the folder where Arc keeps
/// its sidebar file, as a suggestion, and the app never opens or lists that folder itself.
@MainActor
final class ArcImportFeature: AppFeature {
    /// The wizard on screen, if any. Held here until its sheet ends, which is also what lets a second one not start.
    private(set) var activeWizard: ArcImportWizard?

    #if BOW_E2E  // E2E seam: e2e picks the file through this closure and never shows an open panel.
        /// Answers the file picker. An e2e run has no picker: with no closure set the answer is "cancelled".
        var e2eChooseFile: (@MainActor () -> URL?)?
        /// How many times the picker was asked, so a test sees that the wizard asked for the file.
        var e2eFileRequests = 0
    #endif

    init(dataDirectory: URL) {}

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
