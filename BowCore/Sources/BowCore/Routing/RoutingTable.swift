import Foundation

/// What routing decided for one link.
public struct RoutingDecision: Equatable, Sendable {
    public var destination: RouteDestination
    /// The rule that matched, or nil when the default applied.
    public var matchedRuleID: UUID?
    /// The source app after helper processes were mapped to their parent app, or nil when unknown.
    public var sourceBundleID: String?
}

/// A rule that can never be reached because an earlier rule matches every link it would.
public struct ShadowedRule: Equatable, Sendable {
    public var rule: UUID
    public var shadowedBy: UUID
    /// False means the two rules disagree, which usually is a mistake the editor should show.
    public var sameDestination: Bool
}

/// The saved routing state: ordered rules plus a default. The first matching rule wins, so order is the only
/// tie breaker: a more specific rule must sit above a broader one, and `shadowedRules` reports the mistakes.
public struct RoutingTable: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public enum DecodingFailure: Error, Equatable {
        /// The data was saved by a newer version of the app.
        case unsupportedVersion(Int)
    }

    public var version: Int
    public var rules: [RoutingRule]
    public var defaultDestination: RouteDestination

    public init(rules: [RoutingRule] = [], defaultDestination: RouteDestination) {
        self.version = Self.currentVersion
        self.rules = rules
        self.defaultDestination = defaultDestination
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else { throw DecodingFailure.unsupportedVersion(version) }
        self.version = version
        self.rules = try container.decode([RoutingRule].self, forKey: .rules)
        self.defaultDestination = try container.decode(RouteDestination.self, forKey: .defaultDestination)
    }

    /// Picks where a link opens.
    /// - Parameters:
    ///   - url: The link's address as text.
    ///   - sourceBundleID: The bundle identifier of the sending app, or nil when the link has no sender.
    ///   - helperParents: Maps a helper process's bundle identifier to its parent app's, ignoring case.
    ///     Applied once, before any rule is tested.
    public func route(
        url: String, sourceBundleID: String? = nil, helperParents: [String: String] = [:]
    ) -> RoutingDecision {
        let source = Self.resolveSource(sourceBundleID, helperParents: helperParents)
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rule = rules.first(where: { $0.matches(url: address, sourceBundleID: source) }) {
            return RoutingDecision(destination: rule.destination, matchedRuleID: rule.id, sourceBundleID: source)
        }
        return RoutingDecision(destination: defaultDestination, matchedRuleID: nil, sourceBundleID: source)
    }

    static func resolveSource(_ bundleID: String?, helperParents: [String: String]) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        for (helper, parent) in helperParents where helper.caseInsensitiveCompare(bundleID) == .orderedSame {
            return parent
        }
        return bundleID
    }

    /// Rules that cannot be used, with the reason, for the rule editor.
    public var invalidRules: [(rule: UUID, problem: String)] {
        rules.compactMap { rule in rule.problem.map { (rule.id, $0) } }
    }

    /// Rules hidden by an earlier rule. A later rule is hidden when an earlier usable rule has no condition the later one lacks.
    public var shadowedRules: [ShadowedRule] {
        var result: [ShadowedRule] = []
        for (index, rule) in rules.enumerated() where rule.problem == nil {
            let earlier = rules[..<index].first { $0.problem == nil && Self.covers($0, rule) }
            if let earlier {
                result.append(
                    ShadowedRule(
                        rule: rule.id, shadowedBy: earlier.id, sameDestination: earlier.destination == rule.destination)
                )
            }
        }
        return result
    }

    /// True when every link the second rule matches is also matched by the first.
    private static func covers(_ first: RoutingRule, _ second: RoutingRule) -> Bool {
        if let app = first.sourceApp {
            guard let other = second.sourceApp, app.caseInsensitiveCompare(other) == .orderedSame else { return false }
        }
        if let pattern = first.urlPattern {
            guard let other = second.urlPattern else { return false }
            if pattern.style == other.style && pattern.text.caseInsensitiveCompare(other.text) == .orderedSame {
                return true
            }
            // A literal piece of text inside another literal is covered by the shorter one.
            if pattern.style == .contains, other.style == .contains {
                return other.text.range(of: pattern.text, options: [.caseInsensitive, .literal]) != nil
            }
            return false
        }
        return true
    }
}
