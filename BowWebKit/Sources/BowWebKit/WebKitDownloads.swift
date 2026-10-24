import BowCore
import Foundation

/// A profile's downloads. Until downloads arrive with their own slice no tab starts one (a response WebKit cannot
/// show ends its navigation as aborted), so the list stays empty and every control does nothing.
@MainActor
final class WebKitDownloads: EngineDownloads {
    let profileID: ProfileID
    private(set) var items: [DownloadItem] = []
    weak var delegate: (any EngineDownloadsDelegate)?

    init(profileID: ProfileID) {
        self.profileID = profileID
    }

    func pause(_ id: DownloadID) {}
    func resume(_ id: DownloadID) {}
    func cancel(_ id: DownloadID) {}
    func remove(_ id: DownloadID) {}
}
