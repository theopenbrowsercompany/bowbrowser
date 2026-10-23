import Foundation

/// Where a routed link opens. Spaces and profiles are named by ID so routing does not depend on their types,
/// which other parts of the app own.
public enum RouteDestination: Hashable, Sendable, Codable {
    case space(id: String)
    case profile(id: String)
    case littleArc
    case mostRecentWindow

    private enum CodingKeys: String, CodingKey { case kind, id }

    private enum Kind: String, Codable {
        case space, profile
        case littleArc = "little-arc"
        case mostRecentWindow = "most-recent-window"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .space: self = .space(id: try container.decode(String.self, forKey: .id))
        case .profile: self = .profile(id: try container.decode(String.self, forKey: .id))
        case .littleArc: self = .littleArc
        case .mostRecentWindow: self = .mostRecentWindow
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .space(let id):
            try container.encode(Kind.space, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .profile(let id):
            try container.encode(Kind.profile, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .littleArc: try container.encode(Kind.littleArc, forKey: .kind)
        case .mostRecentWindow: try container.encode(Kind.mostRecentWindow, forKey: .kind)
        }
    }
}
