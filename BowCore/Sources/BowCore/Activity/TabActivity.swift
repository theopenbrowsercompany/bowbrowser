import Foundation

/// When each sidebar tab was last active (selected, or in the window that became key), keyed by item ID. The
/// command bar ranks open tabs by it and auto-archive measures a tab's idle time from it.
///
/// It lives in its own versioned JSON file beside the sidebar file, never inside it, so it can change without a
/// sidebar migration. The file is `{"version": 1, "lastActive": {"<item id>": <seconds since 1970>}}`, written
/// atomically. A missing file starts empty; a file that cannot be read or decoded is moved aside untouched and the
/// log starts empty, because a lost time only makes a tab look idle, never loses a tab.
///
/// Not thread safe: the app uses it from the main thread.
public final class TabActivity {
    public enum Origin: Equatable, Sendable {
        case loaded
        case freshBecauseMissing
        /// The file was bad (or its version unknown). `setAsideURL` is where it was moved, nil when moving failed.
        case freshAfterSettingAside(setAsideURL: URL?, reason: String)
    }

    /// The name of the file inside the app's Application Support folder, beside `Sidebar.json`.
    public static let fileName = "TabActivity.json"
    public static let currentVersion = 1

    public let fileURL: URL
    public let openReport: Origin
    public private(set) var lastActive: [SidebarItemID: Date]
    /// True when a change has not reached the file yet.
    public private(set) var hasUnsavedChanges = false

    private let clock: any TimeSource
    private let writer = AtomicFileWriter()

    private struct Contents: Codable {
        var version: Int
        var lastActive: [String: Double]
    }

    public static func fileURL(inApplicationSupportFolder folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    public init(fileURL: URL, clock: any TimeSource = SystemTimeSource()) {
        self.fileURL = fileURL
        self.clock = clock
        AtomicFileWriter.removeLeftovers(for: fileURL)
        var times: [SidebarItemID: Date] = [:]
        var origin = Origin.loaded
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            origin = .freshBecauseMissing
        } else {
            do {
                let contents = try JSONDecoder().decode(Contents.self, from: Data(contentsOf: fileURL))
                guard contents.version == Self.currentVersion else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "unknown version"])
                }
                for (key, seconds) in contents.lastActive where seconds.isFinite {
                    times[SidebarItemID(key)] = Date(timeIntervalSince1970: seconds)
                }
            } catch {
                origin = .freshAfterSettingAside(
                    setAsideURL: Self.setAside(fileURL), reason: String(describing: error))
            }
        }
        lastActive = times
        openReport = origin
    }

    /// Marks `item` active now.
    public func record(_ item: SidebarItemID) {
        lastActive[item] = clock.now
        hasUnsavedChanges = true
    }

    public func lastActive(_ item: SidebarItemID) -> Date? { lastActive[item] }

    /// Forgets every item not in `liveItems`.
    public func prune(keeping liveItems: Set<SidebarItemID>) {
        let kept = lastActive.filter { liveItems.contains($0.key) }
        guard kept.count != lastActive.count else { return }
        lastActive = kept
        hasUnsavedChanges = true
    }

    /// Writes the file atomically (a temporary file, then a rename). A failed write leaves the changes pending.
    public func save() throws {
        let contents = Contents(
            version: Self.currentVersion,
            lastActive: Dictionary(
                uniqueKeysWithValues: lastActive.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer.write(try encoder.encode(contents), to: fileURL)
        hasUnsavedChanges = false
    }

    private static func setAside(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        for attempt in 0..<100 {
            let name = "\(url.lastPathComponent).unreadable-\(stamp)" + (attempt == 0 ? "" : "-\(attempt)")
            let destination = url.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            return (try? FileManager.default.moveItem(at: url, to: destination)) == nil ? nil : destination
        }
        return nil
    }
}
