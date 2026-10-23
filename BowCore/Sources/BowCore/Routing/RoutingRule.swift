import Foundation

/// A text test on the link's address. Both styles ignore case.
public struct URLPattern: Hashable, Sendable, Codable {
    public enum Style: String, Sendable, Codable {
        /// The address contains the text.
        case contains
        /// The text is a regular expression that matches anywhere in the address; anchor it with `^` or `$`.
        case matches
    }

    public var style: Style
    public var text: String

    public init(_ style: Style, _ text: String) {
        self.style = style
        self.text = text
    }

    /// Why the pattern cannot be used, or nil when it is fine.
    public var problem: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "the pattern is empty" }
        if style == .matches, regularExpression == nil { return "the pattern is not a valid regular expression" }
        return nil
    }

    private var regularExpression: NSRegularExpression? {
        try? NSRegularExpression(pattern: text, options: [.caseInsensitive])
    }

    /// An unusable pattern (empty or an invalid expression) matches nothing.
    public func matches(_ url: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch style {
        case .contains:
            return url.range(of: text, options: [.caseInsensitive, .literal]) != nil
        case .matches:
            guard let expression = regularExpression else { return false }
            return expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
    }
}

/// One routing rule. It needs at least one condition; when it has both, both must hold.
public struct RoutingRule: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Matches on the link's address. Nil means any address.
    public var urlPattern: URLPattern?
    /// Matches the app the link came from, by bundle identifier, ignoring case.
    /// Nil means any app, including a link with no known source. A rule with an app never matches a link with no source.
    public var sourceApp: String?
    public var destination: RouteDestination

    public init(
        id: UUID = UUID(), urlPattern: URLPattern? = nil, sourceApp: String? = nil, destination: RouteDestination
    ) {
        self.id = id
        self.urlPattern = urlPattern
        self.sourceApp = sourceApp
        self.destination = destination
    }

    /// Why the rule cannot be used, or nil when it is fine. An unusable rule never matches.
    public var problem: String? {
        if urlPattern == nil && sourceApp == nil { return "the rule has no condition" }
        if let problem = urlPattern?.problem { return problem }
        if let sourceApp, sourceApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "the source app is empty"
        }
        return nil
    }

    public func matches(url: String, sourceBundleID: String?) -> Bool {
        guard problem == nil else { return false }
        if let sourceApp {
            guard let sourceBundleID, sourceBundleID.caseInsensitiveCompare(sourceApp) == .orderedSame else {
                return false
            }
        }
        if let urlPattern, !urlPattern.matches(url) { return false }
        return true
    }
}
