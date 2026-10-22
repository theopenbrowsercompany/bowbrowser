import Foundation

/// Turns what a person types into the address bar or command bar into a URL to load.
public enum AddressInput {
    /// Search engine used when the input is not a web address.
    public static let searchURL = "https://www.google.com/search?q="

    /// Returns the URL for `text`: the text itself when it is already a URL, an https URL when it
    /// looks like a host name, and a search otherwise. Returns nil for blank input.
    public static func resolve(_ text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
            ["http", "https", "file", "about", "chrome"].contains(scheme)
        {
            return url
        }

        if looksLikeHost(input), let url = URL(string: "https://\(input)") {
            return url
        }

        let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input
        return URL(string: searchURL + query)
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(" ") else { return false }
        let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        return name == "localhost" || (name.contains(".") && !name.hasPrefix(".") && !name.hasSuffix("."))
    }
}
