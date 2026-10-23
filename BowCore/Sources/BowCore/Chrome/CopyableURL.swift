import Foundation

/// Which page address Cmd+Shift+C copies. A page on the web (http, https), a local file or an FTP site has one; a
/// blank tab (`about:blank`), an engine or internal page (`chrome:`, `devtools:`, `about:`), a `data:` or
/// `javascript:` address and a tab with no address have none, so copying does nothing for them.
public enum CopyableURL {
    private static let schemes: Set<String> = ["http", "https", "file", "ftp"]

    /// The address to copy for a tab showing `url`, or nil when there is nothing to copy.
    public static func address(for url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        if scheme != "file", url.host?.isEmpty ?? true { return nil }
        return url
    }
}
