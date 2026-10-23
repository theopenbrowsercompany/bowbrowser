import Foundation

// Site permissions: what a page may use (camera, microphone, location and so on), asked once per site and profile
// and remembered. The engine reports requests as `PermissionRequest` values; the app answers each from a
// `SitePermissionStore` when it holds an answer, and otherwise asks the person and records their answer.

/// Something a page can ask to use.
public enum PermissionKind: String, CaseIterable, Codable, Sendable {
    case camera
    case microphone
    /// Capturing the screen, a window or the system's audio.
    case screenCapture
    case geolocation
    case notifications
    case clipboard
    case midiSysex
    case storageAccess
    case windowManagement
    case localFonts
    /// Anything the engine has no kind for yet.
    case other

    /// Whether an answer for this kind is remembered. Screen capture asks every time, because the person picks
    /// what to share each time; storage access belongs to an embedded site under one top level site, which a
    /// per-site answer would leak to every other top level site; and an unknown kind cannot be told apart from
    /// another unknown kind.
    public var isRemembered: Bool {
        switch self {
        case .screenCapture, .storageAccess, .other: false
        default: true
        }
    }
}

/// The site a permission belongs to: a web origin (scheme, host and port), such as `https://meet.example.com`.
/// Permissions never cross origins, so `http://a.test` and `https://a.test` are different sites.
public struct PermissionSite: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The origin as text, lowercased, with the scheme's default port left out.
    public let origin: String

    /// The site of `url`, or nil when it has no web origin to remember an answer for (an `about:`, `data:` or
    /// `file:` URL, or one without a host).
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = components.port, port != defaultPort {
            origin = "\(scheme)://\(host):\(port)"
        } else {
            origin = "\(scheme)://\(host)"
        }
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let url = URL(string: text), let site = PermissionSite(url: url) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad site"))
        }
        self = site
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(origin)
    }

    /// The origin as a URL, for the engine's content settings.
    public var url: URL { URL(string: origin)! }

    public var description: String { origin }
}

/// A page asked to use one or more things at once (a video call asks for camera and microphone together).
public struct PermissionRequest: Equatable, Sendable {
    /// The origin asking, or nil when the engine could not report one.
    public var origin: URL?
    public var kinds: Set<PermissionKind>

    public init(origin: URL?, kinds: Set<PermissionKind>) {
        self.origin = origin
        self.kinds = kinds
    }

    /// The site to remember the answer for, or nil when there is none.
    public var site: PermissionSite? { origin.flatMap(PermissionSite.init(url:)) }
}

/// The answer to a permission request. It covers every kind in the request.
public enum PermissionDecision: Equatable, Sendable {
    case allow
    case deny
    /// Closed without an answer: nothing is granted or remembered, and the page may ask again.
    case dismiss
}

/// A remembered answer for one kind on one site.
public enum SitePermissionSetting: String, Codable, Sendable {
    case allow
    case block
}

/// The remembered permission answers of one profile, by site and kind. A persistent profile keeps them in a
/// JSON file, rewritten atomically on every change; an in-memory profile keeps them only while it runs, so they
/// go away with it. Profiles never share a store, so an answer in one space is never used in another.
@MainActor
public final class SitePermissionStore {
    /// The file the answers are kept in, or nil for an in-memory store.
    public let fileURL: URL?
    private var settings: [PermissionSite: [PermissionKind: SitePermissionSetting]] = [:]
    private let writer = AtomicFileWriter()

    /// The file's format. Written as `version`, so a later format can migrate it.
    struct FileContents: Codable {
        static let currentVersion = 1
        var version: Int
        var sites: [String: [String: SitePermissionSetting]]
    }

    /// A store kept in `fileURL`, reading the answers already there, or an in-memory store when `fileURL` is nil.
    /// A missing file starts empty. A file that cannot be read is moved aside (with a `.unreadable` suffix) and
    /// the store starts empty, so a damaged file makes the browser ask again instead of granting anything.
    /// Kinds and sites the store does not know are skipped.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        AtomicFileWriter.removeLeftovers(for: fileURL)
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let contents = try? JSONDecoder().decode(FileContents.self, from: data),
            contents.version <= FileContents.currentVersion
        else {
            let aside = fileURL.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return
        }
        for (origin, kinds) in contents.sites {
            guard let url = URL(string: origin), let site = PermissionSite(url: url) else { continue }
            for (name, setting) in kinds {
                guard let kind = PermissionKind(rawValue: name), kind.isRemembered else { continue }
                settings[site, default: [:]][kind] = setting
            }
        }
    }

    /// The remembered answer for `kind` on `site`, or nil when the person has not answered.
    public func setting(for kind: PermissionKind, on site: PermissionSite) -> SitePermissionSetting? {
        settings[site]?[kind]
    }

    /// Every site with a remembered answer.
    public var sites: [PermissionSite] { settings.keys.sorted { $0.origin < $1.origin } }

    /// The answer to `request` from what is remembered, or nil when the person must be asked. A request is
    /// denied when any of its kinds is blocked, and allowed only when every kind is allowed. A request without a
    /// site, or with a kind that is never remembered, always asks (unless something in it is blocked).
    public func decision(for request: PermissionRequest) -> PermissionDecision? {
        guard let site = request.site, !request.kinds.isEmpty else { return nil }
        let remembered = request.kinds.map { setting(for: $0, on: site) }
        if remembered.contains(.block) { return .deny }
        if remembered.allSatisfy({ $0 == .allow }) { return .allow }
        return nil
    }

    /// Remembers the person's answer to `request` for each of its kinds that is remembered: allow as allow, deny
    /// as block. A dismissal, or a request without a site, remembers nothing. Returns the settings it stored, so
    /// the caller can hand them to the engine. Throws when the file cannot be written; the answer is still
    /// remembered while the app runs.
    @discardableResult
    public func record(_ decision: PermissionDecision, for request: PermissionRequest) throws -> [PermissionKind:
        SitePermissionSetting]
    {
        guard let site = request.site else { return [:] }
        let setting: SitePermissionSetting
        switch decision {
        case .allow: setting = .allow
        case .deny: setting = .block
        case .dismiss: return [:]
        }
        var stored: [PermissionKind: SitePermissionSetting] = [:]
        for kind in request.kinds where kind.isRemembered {
            settings[site, default: [:]][kind] = setting
            stored[kind] = setting
        }
        if !stored.isEmpty { try save() }
        return stored
    }

    /// Forgets every answer for `site`, so its next request asks again.
    public func reset(_ site: PermissionSite) throws {
        guard settings.removeValue(forKey: site) != nil else { return }
        try save()
    }

    private func save() throws {
        guard let fileURL else { return }
        var sites: [String: [String: SitePermissionSetting]] = [:]
        for (site, kinds) in settings where !kinds.isEmpty {
            sites[site.origin] = Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.rawValue, $0.value) })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(FileContents(version: FileContents.currentVersion, sites: sites))
        try writer.write(data, to: fileURL)
    }
}
