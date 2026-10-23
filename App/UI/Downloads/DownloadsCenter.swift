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
            // An interrupted download keeps its file, since it can resume into it.
            if list.entry(key)?.item.state.isFinal == true { reserved[key] = nil }
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
        let key = DownloadEntry.Key(profileID: downloads.profileID, downloadID: item.id)
        let folder = DownloadSettings.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let choice = DownloadDestination.choose(
            suggestedName: suggestedName,
            folder: folder,
            askWhereToSave: DownloadSettings.askWhereToSave,
            isTaken: { isTaken(folder.appendingPathComponent($0, isDirectory: false), by: key) }
        )
        switch choice {
        case .save(let url):
            reserved[key] = url
            return url
        case .ask(let suggested):
            // Held while the panel is open, so a second download does not suggest the same name.
            reserved[key] = suggested
            guard let picked = await askForDestination(suggested: suggested),
                let state = list.entry(key)?.item.state, !state.isFinal
            else {
                reserved[key] = nil
                return nil
            }
            // The panel already asked before replacing a file on disk; a running download's file is numbered.
            let folder = picked.deletingLastPathComponent()
            let name = DownloadDestination.uniqueFileName(picked.lastPathComponent) {
                $0 != picked.lastPathComponent
                    && FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                    || isReserved(folder.appendingPathComponent($0, isDirectory: false), except: key)
            }
            let url = folder.appendingPathComponent(name, isDirectory: false)
            reserved[key] = url
            return url
        }
    }

    /// True when `url` is a file on disk, Chromium's partial file for it, or the file of another running download.
    private func isTaken(_ url: URL, by key: DownloadEntry.Key) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path) || fileManager.fileExists(atPath: url.path + ".crdownload")
            || isReserved(url, except: key)
    }

    /// True when another download holds `url`. Compared ignoring case, as the default macOS volume does.
    private func isReserved(_ url: URL, except key: DownloadEntry.Key) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return reserved.contains { $0.key != key && $0.value.standardizedFileURL.path.lowercased() == path }
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
