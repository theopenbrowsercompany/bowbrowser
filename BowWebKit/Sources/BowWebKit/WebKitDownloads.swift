import BowCore
import Foundation
import WebKit

/// A profile's downloads on WebKit. A tab's navigation hands each download WebKit begins to its profile's downloads
/// (`adopt(_:)`), which is the `WKDownload`'s delegate and holds it, never the tab: a download goes on after the tab
/// that started it closed and its web view is gone. The app's delegate chooses each destination; without one, no
/// download starts.
///
/// Pausing cancels the WebKit download and keeps WebKit's resume data; resuming hands that data to a web view on the
/// profile's store, made for the purpose and let go once WebKit returned the new download. A paused download WebKit
/// kept no resume data for (its server takes no ranges) starts again from the first byte into the same file.
/// Cancelling deletes what was saved so far. Quitting cancels every download that has not ended.
@MainActor
final class WebKitDownloads: NSObject, EngineDownloads, WKDownloadDelegate {
    let profileID: ProfileID
    weak var delegate: (any EngineDownloadsDelegate)?
    /// The profile's store, which a resumed download runs on.
    private let store: WKWebsiteDataStore
    /// Every download WebKit began on the profile, oldest first, removed ones excepted.
    private var entries: [WebKitDownload] = []
    private var lastID: UInt32 = 0
    private var isQuitting = false

    init(profileID: ProfileID, store: WKWebsiteDataStore) {
        self.profileID = profileID
        self.store = store
    }

    var items: [DownloadItem] { entries.filter(\.isAnnounced).map(\.item) }

    /// Whether a download from `url` may start: only with a delegate to choose its destination, when the delegate
    /// allows it, and never once quitting began.
    func accepts(_ url: URL) -> Bool {
        guard !isQuitting, let delegate else { return false }
        return delegate.downloads(self, shouldAllowDownloadFrom: url)
    }

    /// Takes a download WebKit began from one of the profile's tabs.
    func adopt(_ download: WKDownload) {
        download.delegate = self
        guard !isQuitting else { return download.cancel(nil) }
        lastID += 1
        entries.append(WebKitDownload(id: DownloadID(rawValue: lastID), download: download))
    }

    // MARK: Controls

    func pause(_ id: DownloadID) {
        guard let entry = entry(id), entry.item.canPause, entry.phase == .running, let download = entry.download else {
            return
        }
        entry.phase = .pausing
        _ = entry.readProgress(force: true)
        download.cancel { [weak self, weak entry] data in
            guard let self, let entry, entry.phase == .pausing else { return }
            _ = entry.readProgress(force: true)
            entry.detach()
            entry.phase = .idle
            entry.resumeData = data ?? entry.resumeData
            entry.item.state = .paused
            self.send(.updated(entry.item))
        }
    }

    func resume(_ id: DownloadID) {
        guard let entry = entry(id), entry.item.canResume, entry.phase == .idle, !isQuitting else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        // Only to hand WebKit the download: the new download runs in the network process, and the web view is let
        // go once WebKit returned it.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let resumed: @MainActor (WKDownload) -> Void = { [weak self, weak entry] download in
            withExtendedLifetime(webView) {}
            guard let self, let entry else { return download.cancel(nil) }
            self.resumed(entry, with: download)
        }
        entry.phase = .resuming
        entry.item.state = .inProgress
        if let data = entry.resumeData {
            entry.resumeData = nil
            webView.resumeDownload(fromResumeData: data, completionHandler: resumed)
        } else if let request = entry.request {
            entry.isRestarting = true
            webView.startDownload(using: request, completionHandler: resumed)
        } else {
            entry.phase = .idle
            entry.item.state = .interrupted
        }
        send(.updated(entry.item))
    }

    /// Stops the download for good and deletes what was saved so far.
    func cancel(_ id: DownloadID) {
        guard let entry = entry(id), entry.item.canCancel else { return }
        let download = entry.download
        entry.detach()
        entry.phase = .idle
        entry.resumeData = nil
        entry.isRestarting = false
        entry.item.state = .cancelled
        entry.removePartialFile()
        // WebKit may write what it held once more before it stops; delete that too.
        download?.cancel { [weak entry] _ in entry?.removePartialFile() }
        if entry.isAnnounced { send(.updated(entry.item)) }
    }

    func remove(_ id: DownloadID) {
        guard let index = entries.firstIndex(where: { $0.item.id == id && $0.isAnnounced }),
            entries[index].item.canRemove, entries[index].phase == .idle
        else { return }
        entries.remove(at: index)
        send(.removed(id))
    }

    /// Cancels every download that has not ended (paused ones too), and refuses new ones from now on.
    func cancelAll() {
        isQuitting = true
        for entry in entries where !entry.item.state.isFinal { cancel(entry.item.id) }
    }

    // MARK: WKDownloadDelegate

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        if let entry = restarting(download), let destination = entry.item.destination {
            // A paused download that kept no resume data, started again: the same file, from the first byte.
            entry.isRestarting = false
            entry.phase = .running
            entry.attach(download) { [weak self, weak entry] in self?.progressed(entry) }
            entry.removePartialFile()
            return destination
        }
        guard let entry = entry(download), entry.item.state == .inProgress else { return nil }
        entry.item.url = response.url ?? entry.item.url
        entry.item.suggestedFileName = suggestedFilename
        if response.expectedContentLength >= 0 { entry.item.totalBytes = response.expectedContentLength }
        entry.isAnnounced = true
        send(.created(entry.item))
        let destination = await delegate?.downloads(self, destinationFor: entry.item, suggestedName: suggestedFilename)
        // Cancelled, or the profile began quitting, while the app chose.
        guard entry.download === download, entry.item.state == .inProgress, !isQuitting else { return nil }
        guard let destination else {
            entry.detach()
            entry.phase = .idle
            entry.item.state = .cancelled
            send(.updated(entry.item))
            return nil
        }
        entry.item.destination = destination
        entry.phase = .running
        entry.attach(download) { [weak self, weak entry] in self?.progressed(entry) }
        send(.updated(entry.item))
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = entry(download) else { return }
        _ = entry.readProgress(force: true)
        entry.detach()
        entry.phase = .idle
        entry.resumeData = nil
        if let destination = entry.item.destination,
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
        {
            entry.item.receivedBytes = size
        }
        if entry.item.totalBytes == nil { entry.item.totalBytes = entry.item.receivedBytes }
        entry.item.state = .complete
        send(.updated(entry.item))
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let entry = entry(download) else { return }
        // A pause ends when WebKit hands over its resume data, through the cancel's completion.
        if entry.phase == .pausing {
            entry.resumeData = resumeData ?? entry.resumeData
            return
        }
        _ = entry.readProgress(force: true)
        entry.detach()
        entry.phase = .idle
        entry.isRestarting = false
        entry.resumeData = resumeData
        entry.item.state = .interrupted
        if entry.isAnnounced { send(.updated(entry.item)) }
    }

    // MARK: Inside

    private func entry(_ id: DownloadID) -> WebKitDownload? {
        entries.first { $0.item.id == id }
    }

    private func entry(_ download: WKDownload) -> WebKitDownload? {
        entries.first { $0.download === download }
    }

    /// The download starting again that `download` is, whether WebKit returned it already or asks for its
    /// destination first.
    private func restarting(_ download: WKDownload) -> WebKitDownload? {
        if let entry = entry(download) { return entry.isRestarting ? entry : nil }
        return entries.first {
            $0.isRestarting && $0.phase == .resuming && $0.request?.url == download.originalRequest?.url
        }
    }

    /// A resumed or restarted download WebKit returned for `entry`.
    private func resumed(_ entry: WebKitDownload, with download: WKDownload) {
        download.delegate = self
        // Already running: WebKit asked for its destination before it returned it.
        if entry.download === download { return }
        // Cancelled, or quitting began, meanwhile.
        guard entry.phase == .resuming, entry.item.state == .inProgress, !isQuitting else {
            return download.cancel(nil)
        }
        entry.phase = .running
        entry.attach(download) { [weak self, weak entry] in self?.progressed(entry) }
    }

    private func progressed(_ entry: WebKitDownload?) {
        guard let entry, entry.phase == .running, entry.readProgress() else { return }
        send(.updated(entry.item))
    }

    private func send(_ event: DownloadEvent) {
        delegate?.downloads(self, didReceive: event)
    }
}
