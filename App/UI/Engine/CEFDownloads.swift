import BowCore
import Foundation

/// One bridge profile's downloads as `EngineDownloads`. The adapter is the bridge's downloads delegate and turns
/// what it reports into `DownloadEvent` values for its one `EngineDownloadsDelegate`.
@MainActor
final class CEFDownloads: NSObject, EngineDownloads {
    private let downloads: BowDownloads
    weak var delegate: (any EngineDownloadsDelegate)?

    init(_ downloads: BowDownloads) {
        self.downloads = downloads
        super.init()
        // The bridge holds its delegate weakly; the profile adapter keeps this object for the profile's life.
        downloads.delegate = self
    }

    var profileID: ProfileID { ProfileID(downloads.profileID) }
    var items: [DownloadItem] { downloads.items.map(DownloadItem.init) }

    func pause(_ id: DownloadID) { downloads.pause(id.rawValue) }
    func resume(_ id: DownloadID) { downloads.resume(id.rawValue) }
    func cancel(_ id: DownloadID) { downloads.cancel(id.rawValue) }
    func remove(_ id: DownloadID) { downloads.remove(id.rawValue) }
}

extension CEFDownloads: BowDownloadsDelegate {
    func downloads(_ downloads: BowDownloads, didCreate item: BowDownloadItem) {
        delegate?.downloads(self, didReceive: .created(DownloadItem(item)))
    }

    func downloads(_ downloads: BowDownloads, didUpdate item: BowDownloadItem) {
        delegate?.downloads(self, didReceive: .updated(DownloadItem(item)))
    }

    func downloads(_ downloads: BowDownloads, didRemove item: BowDownloadItem) {
        delegate?.downloads(self, didReceive: .removed(DownloadID(rawValue: item.downloadID)))
    }

    func downloads(
        _ downloads: BowDownloads,
        chooseDestinationFor item: BowDownloadItem,
        suggestedName: String,
        completionHandler: @escaping @Sendable (String?) -> Void
    ) {
        guard let delegate else { return completionHandler(nil) }
        let snapshot = DownloadItem(item)
        Task { @MainActor in
            let destination = await delegate.downloads(self, destinationFor: snapshot, suggestedName: suggestedName)
            completionHandler(destination?.path)
        }
    }

    func downloads(_ downloads: BowDownloads, shouldAllowDownloadFrom url: URL) -> Bool {
        delegate?.downloads(self, shouldAllowDownloadFrom: url) ?? false
    }
}

extension DownloadItem {
    fileprivate init(_ item: BowDownloadItem) {
        let state: DownloadState =
            switch item.state {
            case .inProgress: .inProgress
            case .paused: .paused
            case .complete: .complete
            case .cancelled: .cancelled
            case .interrupted: .interrupted
            case .unknown: .unknown
            @unknown default: .unknown
            }
        self.init(
            id: DownloadID(rawValue: item.downloadID),
            url: item.url,
            suggestedFileName: item.suggestedFileName,
            destination: item.fullPath.map { URL(fileURLWithPath: $0, isDirectory: false) },
            state: state,
            receivedBytes: item.receivedBytes,
            totalBytes: item.totalBytes > 0 ? item.totalBytes : nil,
            bytesPerSecond: item.currentSpeed
        )
    }
}
