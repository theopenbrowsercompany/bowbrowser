import Foundation

/// One thing the Chromium importer did with a file.
public enum ChromiumFileEvent: Equatable, Sendable {
    /// A file in the person's folder was read whole (`Local State`, `Bookmarks`).
    case read(URL)
    /// A file in the person's folder was copied, byte for byte, into a temporary folder (`History` and its side files).
    case copied(from: URL, to: URL)
    /// A database was opened with SQLite. Only copies are ever opened.
    case opened(URL)
    /// A temporary folder was deleted.
    case removed(URL)
}

/// Every file the Chromium importer touches, in order, so the files read can be named and checked. Every reader in
/// `Import/Chromium` records each file it reads, copies or opens here before using it. Safe from any thread.
public final class ChromiumFileLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChromiumFileEvent] = []

    public init() {}

    public func record(_ event: ChromiumFileEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    public var events: [ChromiumFileEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The files in the person's folder that were read or copied, in order.
    public var originals: [URL] {
        events.compactMap { event in
            switch event {
            case .read(let url): url
            case .copied(let from, _): from
            case .opened, .removed: nil
            }
        }
    }
}
