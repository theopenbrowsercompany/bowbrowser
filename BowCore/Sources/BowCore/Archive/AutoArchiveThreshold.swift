import Foundation

/// How long an unpinned tab may sit unused before auto-archive moves it out of Today. The menu is fixed: these seven
/// choices and nothing else.
public enum AutoArchiveThreshold: String, CaseIterable, Codable, Sendable {
    case never
    case oneHour = "1h"
    case sixHours = "6h"
    case twelveHours = "12h"
    case twentyFourHours = "24h"
    case sevenDays = "7d"
    case thirtyDays = "30d"

    /// What a profile uses until its owner picks another threshold.
    public static let `default`: AutoArchiveThreshold = .twelveHours

    /// The idle time that expires a tab, or nil for `never`.
    public var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .oneHour: return 3_600
        case .sixHours: return 6 * 3_600
        case .twelveHours: return 12 * 3_600
        case .twentyFourHours: return 24 * 3_600
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        }
    }

    /// The menu title.
    public var title: String {
        switch self {
        case .never: return "Never"
        case .oneHour: return "1 hour"
        case .sixHours: return "6 hours"
        case .twelveHours: return "12 hours"
        case .twentyFourHours: return "24 hours"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        }
    }
}

/// The auto-archive threshold of each profile. The threshold belongs to the profile, not to a Space: every Space
/// of a profile archives on the same schedule. Codable so the app can keep it wherever it keeps settings.
public struct AutoArchiveSettings: Equatable, Sendable {
    /// Saved values as text, so a value this build does not know (written by a newer build) survives a save.
    private var saved: [String: String]

    public init() { saved = [:] }

    /// The profile's threshold; the default when it never chose or its saved value is not on this build's menu.
    public func threshold(for profile: ProfileID) -> AutoArchiveThreshold {
        saved[profile.rawValue].flatMap { AutoArchiveThreshold(rawValue: $0) } ?? .default
    }

    public mutating func setThreshold(_ threshold: AutoArchiveThreshold, for profile: ProfileID) {
        saved[profile.rawValue] = threshold.rawValue
    }
}

extension AutoArchiveSettings: Codable {
    private enum CodingKeys: String, CodingKey { case thresholds }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        saved = try values.decodeIfPresent([String: String].self, forKey: .thresholds) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(saved, forKey: .thresholds)
    }
}
