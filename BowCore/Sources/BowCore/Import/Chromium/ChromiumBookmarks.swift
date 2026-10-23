import Foundation

/// A bookmark or folder read from a Chromium `Bookmarks` file.
public indirect enum ChromiumBookmarkNode: Equatable, Sendable {
    case url(title: String, url: String, dateAdded: Date?)
    case folder(title: String, dateAdded: Date?, children: [ChromiumBookmarkNode])
}

/// A top level bookmark container.
public struct ChromiumBookmarkRoot: Equatable, Sendable {
    /// The key in `roots`, such as `bookmark_bar`, `other`, `synced` or Arc's `custom_root`.
    public let key: String
    public let title: String
    public let children: [ChromiumBookmarkNode]

    public init(key: String, title: String, children: [ChromiumBookmarkNode]) {
        self.key = key
        self.title = title
        self.children = children
    }
}

public struct ChromiumBookmarks: Equatable, Sendable {
    public static let fileName = "Bookmarks"
    /// Roots in a stable order: bookmark bar, other, synced, then any other key by name.
    public let roots: [ChromiumBookmarkRoot]

    public init(roots: [ChromiumBookmarkRoot]) { self.roots = roots }

    public var bookmarkCount: Int { roots.reduce(0) { $0 + Self.count($1.children).urls } }
    public var folderCount: Int { roots.reduce(0) { $0 + Self.count($1.children).folders } }

    static func count(_ nodes: [ChromiumBookmarkNode]) -> (urls: Int, folders: Int) {
        var urls = 0
        var folders = 0
        for node in nodes {
            switch node {
            case .url: urls += 1
            case .folder(_, _, let children):
                folders += 1
                let inner = count(children)
                urls += inner.urls
                folders += inner.folders
            }
        }
        return (urls, folders)
    }

    public static func parse(data: Data) throws -> ChromiumBookmarks {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ChromiumImportError.malformed(file: fileName, reason: "not valid JSON")
        }
        guard let object = json as? [String: Any], let roots = object["roots"] as? [String: Any] else {
            throw ChromiumImportError.malformed(file: fileName, reason: "no roots object")
        }
        let parsed = roots.compactMap { key, value -> ChromiumBookmarkRoot? in
            // Entries such as `sync_transaction_version` are plain values, not containers.
            guard let node = value as? [String: Any], node["children"] is [Any] else { return nil }
            return ChromiumBookmarkRoot(
                key: key,
                title: (node["name"] as? String) ?? key,
                children: children(of: node)
            )
        }
        let order = ["bookmark_bar", "other", "synced"]
        let sorted = parsed.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? order.count
            let ib = order.firstIndex(of: b.key) ?? order.count
            return ia == ib ? a.key < b.key : ia < ib
        }
        return ChromiumBookmarks(roots: sorted)
    }

    public static func load(profileFolder: URL) throws -> ChromiumBookmarks {
        let url = profileFolder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ChromiumImportError.missingFile(fileName) }
        guard let data = try? Data(contentsOf: url) else {
            throw ChromiumImportError.malformed(file: fileName, reason: "the file is not readable")
        }
        return try parse(data: data)
    }

    /// Entries with an unknown type, or a URL entry without a URL, are skipped.
    private static func children(of node: [String: Any]) -> [ChromiumBookmarkNode] {
        guard let list = node["children"] as? [Any] else { return [] }
        return list.compactMap { item -> ChromiumBookmarkNode? in
            guard let entry = item as? [String: Any], let type = entry["type"] as? String else { return nil }
            let title = (entry["name"] as? String) ?? ""
            let added = dateAdded(entry["date_added"])
            switch type {
            case "url":
                guard let url = entry["url"] as? String, !url.isEmpty else { return nil }
                return .url(title: title, url: url, dateAdded: added)
            case "folder":
                return .folder(title: title, dateAdded: added, children: children(of: entry))
            default:
                return nil
            }
        }
    }

    /// Chromium writes `date_added` as a string of WebKit microseconds; accept a number too.
    private static func dateAdded(_ value: Any?) -> Date? {
        if let text = value as? String, let micros = Int64(text) { return ChromiumTime.date(microseconds: micros) }
        if let number = value as? NSNumber { return ChromiumTime.date(microseconds: number.int64Value) }
        return nil
    }
}
