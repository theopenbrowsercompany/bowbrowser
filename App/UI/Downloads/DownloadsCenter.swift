import AppKit
import BowCore

/// Where downloads go, kept in `AppSettings.defaults` (e2e runs point the folder at their own throwaway folder).
@MainActor
enum DownloadSettings {
    static let folderKey = "downloads.folder"
    static let askWhereToSaveKey = "downloads.askWhereToSave"

    /// The folder downloads save to: the user's Downloads folder unless a setting names another.
    static var folder: URL {
        get {
            if let path = AppSettings.defaults.string(forKey: folderKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        set { AppSettings.defaults.set(newValue.path, forKey: folderKey) }
    }

    /// When true, every download opens a save panel instead of saving straight into `folder`.
    static var askWhereToSave: Bool {
        get { AppSettings.defaults.bool(forKey: askWhereToSaveKey) }
        set { AppSettings.defaults.set(newValue, forKey: askWhereToSaveKey) }
    }
}

/// The app's downloads: the delegate of every profile's downloads, the list the downloads window shows, and the
/// controls behind its buttons. Destinations are chosen here, so two downloads never write to one file.
@MainActor
final class DownloadsCenter: EngineDownloadsDelegate {
    private(set) var list = DownloadList()
    /// Called after every change to `list`.
    var onChange: (() -> Void)?

    /// Each profile's downloads, by profile, held so controls reach them.
    private var profiles: [ProfileID: any EngineDownloads] = [:]
    /// Files chosen for downloads that are still running, which a new download must not take.
    private var reserved: [DownloadEntry.Key: URL] = [:]
    /// The window save panels attach to, when one is open.
    var panelWindow: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }

    /// Starts handling `profile`'s downloads. Safe to call again for the same profile.
    func observe(_ profile: any EngineProfile) {
        guard profiles[profile.profileID] == nil else { return }
        let downloads = profile.downloads
        profiles[profile.profileID] = downloads
        downloads.delegate = self
    }

    func pause(_ entry: DownloadEntry) { profiles[entry.profileID]?.pause(entry.item.id) }
    func resume(_ entry: DownloadEntry) { profiles[entry.profileID]?.resume(entry.item.id) }
    func cancel(_ entry: DownloadEntry) { profiles[entry.profileID]?.cancel(entry.item.id) }
    func remove(_ entry: DownloadEntry) { profiles[entry.profileID]?.remove(entry.item.id) }

    // MARK: EngineDownloadsDelegate

    func downloads(_ downloads: any EngineDownloads, didReceive event: DownloadEvent) {
        let profileID = downloads.profileID
        guard list.apply(event, from: profileID) else { return }
        switch event {
        case .created(let item), .updated(let item):
            let key = DownloadEntry.Key(profileID: profileID, downloadID: item.id)
            if let state = list.entry(key)?.item.state, state.isFinal || state == .interrupted {
                reserved[key] = nil
            }
        case .removed(let id):
            reserved[DownloadEntry.Key(profileID: profileID, downloadID: id)] = nil
        }
        onChange?()
    }

    func downloads(
        _ downloads: any EngineDownloads,
        destinationFor item: DownloadItem,
        suggestedName: String
    ) async -> URL? {
        let folder = DownloadSettings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let choice = DownloadDestination.choose(
            suggestedName: suggestedName,
            folder: folder,
            askWhereToSave: DownloadSettings.askWhereToSave,
            isTaken: { [reserved] name in
                let url = folder.appendingPathComponent(name, isDirectory: false)
                let fileManager = FileManager.default
                return fileManager.fileExists(atPath: url.path)
                    || fileManager.fileExists(atPath: url.path + ".crdownload")
                    || reserved.values.contains { $0.standardizedFileURL == url.standardizedFileURL }
            }
        )
        let destination: URL?
        switch choice {
        case .save(let url):
            destination = url
        case .ask(let suggested):
            destination = await askForDestination(suggested: suggested)
        }
        let key = DownloadEntry.Key(profileID: downloads.profileID, downloadID: item.id)
        if let destination { reserved[key] = destination }
        return destination
    }

    /// Opens a save panel on `suggested`, as a sheet when a window is available. Nil when the person cancels.
    private func askForDestination(suggested: URL) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window = panelWindow() {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}
