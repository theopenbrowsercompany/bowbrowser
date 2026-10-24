import Foundation

/// One stored icon file as the storage reports it.
public struct FaviconFile: Equatable, Sendable {
    public var name: String
    public var bytes: Int
    /// Grows with each write: a larger number is a newer file. Files compare by it when the cap evicts.
    public var order: Int64

    public init(name: String, bytes: Int, order: Int64) {
        self.name = name
        self.bytes = bytes
        self.order = order
    }
}

/// Where icon files live, per profile. Injected so tests need no disk; the app uses `FaviconFolderStorage`.
public protocol FaviconStorage: Sendable {
    func read(profile: String, name: String) -> Data?
    func write(profile: String, name: String, data: Data) throws
    func remove(profile: String, name: String)
    func list(profile: String) -> [FaviconFile]
}

/// Saves and reads one PNG icon per sidebar item for one profile, with the fallbacks of `FaviconLookup`.
///
/// Arc keeps a saved icon with each tab, so an unloaded row still shows its icon after a relaunch. Saving an icon for an
/// item also saves it under the item's exact page address and its host, so a row without an icon of its own can borrow
/// one. The folder stays under a size cap: when a save pushes it over, icons that no item uses go first (the oldest
/// first), and an icon an item still uses is never evicted.
public struct FaviconStore: Sendable {
    public static let defaultCapBytes = 8 * 1024 * 1024
    public static let defaultMaxIconBytes = 256 * 1024

    public let profile: String
    private let storage: any FaviconStorage
    private let capBytes: Int
    private let maxIconBytes: Int
    private let inUse: @Sendable () -> Set<String>

    /// - Parameters:
    ///   - capBytes: the most the profile's icons may take, kept by eviction after each save.
    ///   - maxIconBytes: a larger icon is refused as no icon.
    ///   - inUseItemIDs: the sidebar item IDs that exist now; their icons are kept when the cap evicts.
    public init(
        profile: String,
        storage: any FaviconStorage,
        capBytes: Int = FaviconStore.defaultCapBytes,
        maxIconBytes: Int = FaviconStore.defaultMaxIconBytes,
        inUseItemIDs: @escaping @Sendable () -> Set<String> = { [] }
    ) {
        self.profile = profile
        self.storage = storage
        self.capBytes = capBytes
        self.maxIconBytes = maxIconBytes
        self.inUse = inUseItemIDs
    }

    /// Saves `png` as the icon of `itemID` and, for a web page address, as that page's and that host's icon.
    /// Returns false, saving nothing, for data that is not a whole PNG, or one over the size limit.
    @discardableResult
    public func save(_ png: Data, itemID: String, pageURL: String? = nil) -> Bool {
        guard png.count <= maxIconBytes, Self.isWholePNG(png) else { return false }
        var saved = false
        for source in FaviconLookup.sources(itemID: itemID, pageURL: pageURL) {
            do {
                try storage.write(profile: profile, name: FaviconLookup.fileName(for: source), data: png)
                saved = true
            } catch {
                continue
            }
        }
        if saved { evictToCap() }
        return saved
    }

    /// The icon for the item: its own, else the exact page's, else the host's, else nil.
    /// A missing, empty or damaged file counts as no icon and the next source is tried.
    public func icon(itemID: String, pageURL: String? = nil) -> Data? {
        for source in FaviconLookup.sources(itemID: itemID, pageURL: pageURL) {
            if let data = storage.read(profile: profile, name: FaviconLookup.fileName(for: source)),
                Self.isWholePNG(data)
            {
                return data
            }
        }
        return nil
    }

    /// Drops the item's own icon; the page and host icons stay for other rows.
    public func remove(itemID: String) {
        storage.remove(profile: profile, name: FaviconLookup.fileName(for: .item(itemID)))
    }

    /// Total bytes the profile's icons take.
    public var totalBytes: Int { storage.list(profile: profile).reduce(0) { $0 + $1.bytes } }

    /// Brings the folder under the cap. Order: item icons of items that no longer exist, then page and host icons,
    /// each oldest first. Icons of items in use stay even when that leaves the folder over the cap.
    public func evictToCap() {
        var files = storage.list(profile: profile)
        var total = files.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return }
        let live = inUse()
        func rank(_ file: FaviconFile) -> Int? {
            if let id = FaviconLookup.itemID(fromFileName: file.name) { return live.contains(id) ? nil : 0 }
            return 1
        }
        files.sort { ($0.order, $0.name) < ($1.order, $1.name) }
        for tier in 0...1 {
            for file in files where rank(file) == tier {
                guard total > capBytes else { return }
                storage.remove(profile: profile, name: file.name)
                total -= file.bytes
            }
        }
    }

    /// True for data that starts with the PNG signature, has an IHDR chunk first and ends with the IEND chunk.
    static func isWholePNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let end: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count + 25 + end.count else { return false }
        guard Array(bytes.prefix(signature.count)) == signature else { return false }
        guard Array(bytes[12..<16]) == [0x49, 0x48, 0x44, 0x52] else { return false }
        return Array(bytes.suffix(end.count)) == end
    }
}

/// Keeps icons in memory, for tests and previews.
public final class FaviconMemoryStorage: FaviconStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: [String: (data: Data, order: Int64)]] = [:]
    private var counter: Int64 = 0

    public init() {}

    public func read(profile: String, name: String) -> Data? {
        lock.withLock { files[profile]?[name]?.data }
    }

    public func write(profile: String, name: String, data: Data) throws {
        lock.withLock {
            counter += 1
            files[profile, default: [:]][name] = (data, counter)
        }
    }

    public func remove(profile: String, name: String) {
        lock.withLock { _ = files[profile]?.removeValue(forKey: name) }
    }

    public func list(profile: String) -> [FaviconFile] {
        lock.withLock {
            (files[profile] ?? [:]).map { FaviconFile(name: $0.key, bytes: $0.value.data.count, order: $0.value.order) }
        }
    }
}

/// Keeps icons as files in `<root>/<profile>/`, written atomically.
public struct FaviconFolderStorage: FaviconStorage {
    public let root: URL

    public init(root: URL) { self.root = root }

    private func folder(_ profile: String) -> URL {
        root.appendingPathComponent(profile.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "_")
    }

    public func read(profile: String, name: String) -> Data? {
        try? Data(contentsOf: folder(profile).appendingPathComponent(name))
    }

    public func write(profile: String, name: String, data: Data) throws {
        try AtomicFileWriter().write(data, to: folder(profile).appendingPathComponent(name))
    }

    public func remove(profile: String, name: String) {
        try? FileManager.default.removeItem(at: folder(profile).appendingPathComponent(name))
    }

    public func list(profile: String) -> [FaviconFile] {
        let url = folder(profile)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".png"), !name.hasPrefix(".") else { return nil }
            let values = try? url.appendingPathComponent(name).resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            guard let size = values?.fileSize else { return nil }
            let stamp = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            return FaviconFile(name: name, bytes: size, order: Int64(stamp * 1000))
        }
    }
}
