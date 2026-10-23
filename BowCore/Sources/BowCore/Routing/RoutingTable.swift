import Foundation

/// What routing decided for one link.
public struct RoutingDecision: Equatable, Sendable {
    /// Why the destination was chosen.
    public enum Basis: Equatable, Sendable {
        /// The rule with this ID matched.
        case rule(UUID)
        /// No rule matched and the link has no source app, so the "no source" fallback applied.
        case noSource
        /// No rule matched (or the destination chosen first is gone), so the default applied.
        case defaultDestination
    }

    public var destination: RouteDestination
    /// The rule that matched, or nil when a fallback applied.
    public var matchedRuleID: UUID?
    /// The source app after helper processes were mapped to their parent app, or nil when unknown.
    public var sourceBundleID: String?
    public var basis: Basis
    /// The destination a rule or fallback named but that no longer exists (a deleted Space or profile), which the
    /// default replaced; nil when the first choice was used.
    public var unavailable: RouteDestination?

    public init(
        destination: RouteDestination, matchedRuleID: UUID?, sourceBundleID: String?, basis: Basis? = nil,
        unavailable: RouteDestination? = nil
    ) {
        self.destination = destination
        self.matchedRuleID = matchedRuleID
        self.sourceBundleID = sourceBundleID
        self.basis = basis ?? matchedRuleID.map(Basis.rule) ?? .defaultDestination
        self.unavailable = unavailable
    }
}

/// A rule that cannot be used, and why.
public struct InvalidRule: Equatable, Sendable {
    public var rule: UUID
    public var problem: String

    public init(rule: UUID, problem: String) {
        self.rule = rule
        self.problem = problem
    }
}

/// A rule that can never be reached because an earlier rule matches every link it would.
public struct ShadowedRule: Equatable, Sendable {
    public var rule: UUID
    public var shadowedBy: UUID
    /// False means the two rules disagree, which usually is a mistake the editor should show.
    public var sameDestination: Bool

    public init(rule: UUID, shadowedBy: UUID, sameDestination: Bool) {
        self.rule = rule
        self.shadowedBy = shadowedBy
        self.sameDestination = sameDestination
    }
}

/// The saved routing state: ordered rules plus a default. The first matching rule wins, so order is the only
/// tie breaker: a more specific rule must sit above a broader one, and `shadowedRules` reports the mistakes.
public struct RoutingTable: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public enum DecodingFailure: Error, Equatable {
        /// The data was saved by a newer version of the app.
        case unsupportedVersion(Int)
    }

    public private(set) var version: Int
    public var rules: [RoutingRule]
    public var defaultDestination: RouteDestination
    /// Where a link with no source app goes when no rule matches it (a link from a command line tool, or from an app
    /// that hands links to `/usr/bin/open`, whose sender cannot be named). Nil means the default.
    public var noSourceDestination: RouteDestination?

    /// The table a person starts with: no rules, and links go to Little Arc, which follows the "links from other apps
    /// open in Little Arc" setting, as Arc does before any rule exists.
    public static let initial = RoutingTable(defaultDestination: .littleArc)

    public init(
        rules: [RoutingRule] = [], defaultDestination: RouteDestination, noSourceDestination: RouteDestination? = nil
    ) {
        self.version = Self.currentVersion
        self.rules = rules
        self.defaultDestination = defaultDestination
        self.noSourceDestination = noSourceDestination
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(version) else { throw DecodingFailure.unsupportedVersion(version) }
        self.version = version
        self.rules = try container.decode([RoutingRule].self, forKey: .rules)
        self.defaultDestination = try container.decode(RouteDestination.self, forKey: .defaultDestination)
        self.noSourceDestination = try container.decodeIfPresent(
            RouteDestination.self, forKey: .noSourceDestination)
    }

    private enum CodingKeys: String, CodingKey { case version, rules, defaultDestination, noSourceDestination }

    /// Always writes the current version, so a list read from an older version is saved in the current format.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(rules, forKey: .rules)
        try container.encode(defaultDestination, forKey: .defaultDestination)
        try container.encodeIfPresent(noSourceDestination, forKey: .noSourceDestination)
    }

    /// Picks where a link opens.
    /// - Parameters:
    ///   - url: The link's address as text.
    ///   - sourceBundleID: The bundle identifier of the sending app, or nil when the link has no sender.
    ///   - helperParents: Maps a helper process's bundle identifier to its parent app's, ignoring case.
    ///     Applied once, before any rule is tested.
    ///   - isAvailable: Whether a destination still exists (a Space or profile can be deleted after a rule names
    ///     it). A rule or fallback naming a destination that is gone gives way to the default, and a default that is
    ///     gone to the most recent window, so the link still opens.
    public func route(
        url: String, sourceBundleID: String? = nil, helperParents: [String: String] = [:],
        isAvailable: (RouteDestination) -> Bool = { _ in true }
    ) -> RoutingDecision {
        let source = Self.resolveSource(sourceBundleID, helperParents: helperParents)
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let first: (RouteDestination, RoutingDecision.Basis)
        if let rule = rules.first(where: { $0.matches(url: address, sourceBundleID: source) }) {
            first = (rule.destination, .rule(rule.id))
        } else if source == nil, let noSourceDestination {
            first = (noSourceDestination, .noSource)
        } else {
            first = (defaultDestination, .defaultDestination)
        }
        if isAvailable(first.0) {
            let ruleID: UUID? = if case .rule(let id) = first.1 { id } else { nil }
            return RoutingDecision(destination: first.0, matchedRuleID: ruleID, sourceBundleID: source, basis: first.1)
        }
        let fallback = isAvailable(defaultDestination) ? defaultDestination : .mostRecentWindow
        return RoutingDecision(
            destination: fallback, matchedRuleID: nil, sourceBundleID: source, basis: .defaultDestination,
            unavailable: first.0)
    }

    static func resolveSource(_ bundleID: String?, helperParents: [String: String]) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        // Sorted so that keys differing only by case resolve the same way every time.
        let match = helperParents.keys.sorted().first { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
        guard let match, let parent = helperParents[match] else { return bundleID }
        return parent.isEmpty ? nil : parent
    }

    /// Rules that cannot be used, with the reason, for the rule editor.
    public var invalidRules: [InvalidRule] {
        rules.compactMap { rule in rule.problem.map { InvalidRule(rule: rule.id, problem: $0) } }
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
