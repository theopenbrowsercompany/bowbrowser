import BowCore
import Foundation
import WebKit

/// One download of a profile, for its whole life: the snapshot Bow pushes (`item`), the WebKit download running it
/// now, if any, and what resuming it needs. `WebKitDownloads` owns it and makes every change.
@MainActor
final class WebKitDownload {
    /// What WebKit is doing with the download.
    enum Phase {
        /// WebKit asked where to save it, and the app has not answered yet.
        case choosingDestination
        /// Receiving bytes.
        case running
        /// Cancelled with resume data asked for; WebKit has not handed the data over yet.
        case pausing
        /// Resuming: a new WebKit download for it is on its way.
        case resuming
        /// No WebKit download runs it (paused, failed, or ended).
        case idle
    }

    var item: DownloadItem
    var phase: Phase
    /// The request that started it, to start it again when it kept no resume data.
    let request: URLRequest?
    /// True once `created` was sent; until then the download is not in the list.
    var isAnnounced = false
    /// True while it starts again from the first byte into the destination it already has.
    var isRestarting = false
    /// What WebKit needs to resume where it stopped (`WKWebView.resumeDownload(fromResumeData:)`).
    var resumeData: Data?
    /// The WebKit download running it now. Held strongly: the profile's downloads keep a running download, never
    /// its tab, so it goes on after its tab closed.
    private(set) var download: WKDownload?

    private var observations: [NSKeyValueObservation] = []
    /// The byte count and time the rate was measured from last.
    private var sample: (time: Date, bytes: Int64)?
    /// When progress was pushed last, to send at most ten updates a second.
    private var pushed = Date.distantPast

    init(id: DownloadID, download: WKDownload) {
        item = DownloadItem(id: id, url: download.originalRequest?.url)
        request = download.originalRequest
        phase = .choosingDestination
        attach(download, onProgress: {})
    }

    /// Makes `download` the one running this; `onProgress` runs on the main actor when it received more bytes.
    func attach(_ download: WKDownload, onProgress: @escaping @MainActor () -> Void) {
        detach()
        self.download = download
        let changed: @Sendable () -> Void = { Task { @MainActor in onProgress() } }
        observations = [
            download.progress.observe(\.completedUnitCount) { _, _ in changed() },
            download.progress.observe(\.totalUnitCount) { _, _ in changed() },
        ]
    }

    /// Lets the WebKit download go: its later callbacks find no download and change nothing.
    func detach() {
        for observation in observations { observation.invalidate() }
        observations = []
        download = nil
        sample = nil
        item.bytesPerSecond = 0
    }

    /// Reads the running download's progress into `item`. True when it is time to push it: at most ten times a
    /// second, unless `force`.
    func readProgress(force: Bool = false) -> Bool {
        guard let progress = download?.progress else { return false }
        let total = progress.totalUnitCount
        var received = max(progress.completedUnitCount, 0)
        // A resumed download may count only the bytes still to come; the bytes saved before it come first.
        if total > 0, let known = item.totalBytes, total < known { received += known - total }
        if total > 0, item.totalBytes == nil { item.totalBytes = total }
        let now = Date()
        if let sample, now.timeIntervalSince(sample.time) >= 0.5 {
            item.bytesPerSecond = max(Int64(Double(received - sample.bytes) / now.timeIntervalSince(sample.time)), 0)
            self.sample = (now, received)
        } else if sample == nil {
            sample = (now, received)
        }
        guard received != item.receivedBytes || force else { return false }
        item.receivedBytes = max(received, item.receivedBytes)
        guard force || now.timeIntervalSince(pushed) >= 0.1 else { return false }
        pushed = now
        return true
    }

    /// Deletes what was saved so far at the destination, if anything was.
    func removePartialFile() {
        guard let destination = item.destination else { return }
        try? FileManager.default.removeItem(at: destination)
    }
}
