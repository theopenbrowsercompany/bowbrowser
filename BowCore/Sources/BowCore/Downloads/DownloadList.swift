import Foundation

/// One download in the app's list, with the profile it belongs to (download IDs are unique only per profile).
public struct DownloadEntry: Equatable, Sendable, Identifiable {
    public struct Key: Hashable, Sendable {
        public var profileID: ProfileID
        public var downloadID: DownloadID

        public init(profileID: ProfileID, downloadID: DownloadID) {
            self.profileID = profileID
            self.downloadID = downloadID
        }
    }

    public var profileID: ProfileID
    public var item: DownloadItem

    public init(profileID: ProfileID, item: DownloadItem) {
        self.profileID = profileID
        self.item = item
    }

    public var id: Key { Key(profileID: profileID, downloadID: item.id) }
}

/// The downloads list the app shows: every profile's downloads, newest first, built from their events.
///
/// It keeps the list consistent whatever order events arrive in: an update for a download it has not seen adds
/// it, a second `created` counts as an update, and a final download (complete or cancelled) never changes state
/// again, so a late progress update cannot bring a finished row back to life.
public struct DownloadList: Equatable, Sendable {
    /// Newest first.
    public private(set) var entries: [DownloadEntry] = []

    public init() {}

    /// How many downloads are running now (paused ones are not): the sidebar's downloads button shows activity while
    /// this is above zero.
    public var activeCount: Int {
        entries.lazy.filter { $0.item.state == .inProgress }.count
    }

    public func entry(_ key: DownloadEntry.Key) -> DownloadEntry? {
        entries.first { $0.id == key }
    }

    /// Applies one event from `profileID`'s downloads. Returns true when the list changed.
    @discardableResult
    public mutating func apply(_ event: DownloadEvent, from profileID: ProfileID) -> Bool {
        switch event {
        case .created(let item), .updated(let item):
            let key = DownloadEntry.Key(profileID: profileID, downloadID: item.id)
            guard let index = entries.firstIndex(where: { $0.id == key }) else {
                entries.insert(DownloadEntry(profileID: profileID, item: item), at: 0)
                return true
            }
            let current = entries[index].item
            var next = item
            if current.state.isFinal {
                // Final states stay; only details the engine fills in late (the path, the size) are taken.
                next.state = current.state
                next.receivedBytes = current.receivedBytes
                next.bytesPerSecond = 0
            }
            if next.state != .inProgress { next.bytesPerSecond = 0 }
            if next.destination == nil { next.destination = current.destination }
            guard next != current else { return false }
            entries[index].item = next
            return true
        case .removed(let id):
            let key = DownloadEntry.Key(profileID: profileID, downloadID: id)
            guard let index = entries.firstIndex(where: { $0.id == key }) else { return false }
            entries.remove(at: index)
            return true
        }
    }
}
