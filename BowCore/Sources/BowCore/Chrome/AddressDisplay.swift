import Foundation

/// What the sidebar's URL field shows for the shown tab. Like Arc's sidebar URL bar, it shows the site, not the whole
/// address: the host without the scheme or a leading `www.`, then the path unless it is just `/` (no query, no
/// fragment, no trailing slash), keeping a port that is not the scheme's default (`localhost:3000`). A local file shows its file name. A tab with no address worth
/// showing (a blank tab, an internal page, a `data:` address, none at all) shows the placeholder instead, the same
/// tabs Copy Current URL copies nothing for (`CopyableURL`). The full address is one click away in the command bar.
public enum AddressDisplay {
    /// The field's text when the tab has no address to show.
    public static let placeholder = "Search or type a URL"

    /// The text for a tab showing `url`, or nil to show `placeholder`.
    public static func text(for url: URL?) -> String? {
        guard let url = CopyableURL.address(for: url), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" {
            let name = url.lastPathComponent
            return name.isEmpty || name == "/" ? url.path : name
        }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        // `www.com` is the site's own name, not a `www.` subdomain of one.
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        // An IPv6 address keeps the brackets it needs beside a port.
        if host.contains(":") { host = "[\(host)]" }
        if let port = url.port, port != defaultPorts[scheme] { host += ":\(port)" }
        // The path follows without its trailing slash (`URL.path` drops it); no query or fragment.
        let path = url.path
        return path.isEmpty || path == "/" ? host : host + path
    }

    private static let defaultPorts = ["http": 80, "https": 443, "ftp": 21]
}

/// How the URL field marks the connection to the page it names.
public enum AddressSecurity: Equatable, Sendable {
    /// The usual lock.
    case standard
    /// The page could not be shown securely (its certificate failed): a crossed lock, as Chrome and Arc mark it.
    case notSecure
}

/// What the URL field shows: its text (nil for the placeholder) and how it marks the connection.
public struct AddressLine: Equatable, Sendable {
    public var text: String?
    public var security: AddressSecurity

    public init(text: String?, security: AddressSecurity = .standard) {
        self.text = text
        self.security = security
    }

    /// The line for a tab at `url`: its address with the usual lock.
    public static func tab(_ url: URL?) -> AddressLine {
        AddressLine(text: AddressDisplay.text(for: url))
    }
}
