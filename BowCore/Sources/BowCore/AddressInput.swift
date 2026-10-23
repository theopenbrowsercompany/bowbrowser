import Foundation

/// Turns what a person types into the address bar or command bar into a URL to load.
public enum AddressInput {
    /// Search engine used when the input is not a web address.
    public static let searchURL = "https://www.google.com/search?q="

    /// What a piece of typed text means.
    public enum Interpretation: Equatable, Sendable {
        /// Blank input: nothing to load.
        case empty
        /// A complete address the person typed, kept as is.
        case url(URL)
        /// A host name, with or without a path, that gets an https scheme.
        case host(URL)
        /// Anything else, sent to the search engine.
        case search(URL)

        /// The URL to load, or nil for blank input.
        public var url: URL? {
            switch self {
            case .empty: nil
            case .url(let url), .host(let url), .search(let url): url
            }
        }

        /// True when the person typed an address rather than search words.
        public var isAddress: Bool {
            switch self {
            case .url, .host: true
            case .empty, .search: false
            }
        }
    }

    /// Characters kept as they are inside the search text: `&`, `=`, `+` and `#` must be escaped
    /// or they would end the query early.
    private static let searchAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        return allowed
    }()

    /// Returns the URL for `text`: the text itself when it is already a URL, an https URL when it
    /// looks like a host name, and a search otherwise. Returns nil for blank input.
    public static func resolve(_ text: String) -> URL? {
        interpret(text).url
    }

    /// Classifies `text` and builds the URL it leads to.
    public static func interpret(_ text: String) -> Interpretation {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .empty }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
            ["http", "https", "file", "about", "chrome"].contains(scheme)
        {
            return .url(url)
        }

        if looksLikeHost(input), let url = URL(string: "https://\(input)") {
            return .host(url)
        }

        return .search(searchURL(for: input))
    }

    /// The search engine URL for `text`, whatever the text looks like.
    public static func searchURL(for text: String) -> URL {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = input.addingPercentEncoding(withAllowedCharacters: searchAllowed) ?? input
        return URL(string: searchURL + query) ?? URL(string: searchURL)!
    }

    private static func looksLikeHost(_ input: String) -> Bool {
        guard !input.contains(where: \.isWhitespace) else { return false }
        let host = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        let name = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        if name.lowercased() == "localhost" { return true }
        guard name.contains("."), !name.hasPrefix("."), !name.hasSuffix("."), !name.contains("..") else {
            return false
        }
        // Digits and dots only is an IPv4 address or a number such as 3.14.
        if name.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) { return isIPv4(name) }
        return true
    }

    private static func isIPv4(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { $0 <= 255 } ?? false }
    }
}
