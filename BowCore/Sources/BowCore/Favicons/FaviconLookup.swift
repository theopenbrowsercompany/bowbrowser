import CryptoKit
import Foundation

/// Where a saved site icon can come from, in the order a row looks for one.
public enum FaviconSource: Equatable, Sendable {
    /// The icon saved for this sidebar item itself.
    case item(String)
    /// The icon saved for this exact page address (fragment ignored).
    case page(String)
    /// The icon saved for this site, shared by every page on it.
    case host(String)
}

/// The fallback order for an item's icon: its own, then the exact page address, then the host, then none.
/// Arc keeps a saved icon per tab, so an unloaded row keeps its icon; a row that never had one borrows a sibling's.
public enum FaviconLookup {
    public static func sources(itemID: String, pageURL: String?) -> [FaviconSource] {
        var result: [FaviconSource] = [.item(itemID)]
        guard let pageURL, let url = URL(string: pageURL),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty
        else { return result }
        result.append(.page(pageKey(url)))
        result.append(.host(host))
        return result
    }

    /// The page address with its fragment removed, so `#section` links share one icon.
    static func pageKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        return parts.string ?? url.absoluteString
    }

    /// The file name an icon's source is stored under: letters, digits, dot and dash only, so no source can escape
    /// its folder.
    static func fileName(for source: FaviconSource) -> String {
        switch source {
        case .item(let id): return "item-" + safe(id) + ".png"
        case .page(let key): return "page-" + digest(key) + ".png"
        case .host(let host): return "host-" + safe(host) + ".png"
        }
    }

    static func isItemFile(_ name: String) -> Bool { name.hasPrefix("item-") }

    static func itemID(fromFileName name: String) -> String? {
        guard isItemFile(name), name.hasSuffix(".png") else { return nil }
        let encoded = String(name.dropFirst("item-".count).dropLast(".png".count))
        return encoded.removingPercentEncoding
    }

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")

    /// Percent encodes everything but letters, digits and dash; a dot is encoded too so `..` cannot appear.
    private static func safe(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
