import Foundation

// Answering a page's own check of its permission state (`navigator.permissions.query`) from Bow's store. On
// WebKit nothing keeps a grant across a new web view, so the engine wiring asks these functions instead of the
// engine's settings; they take and return plain values and know no engine.

/// The Permissions API's three states.
public enum PermissionState: String, Equatable, Sendable {
    case granted
    case denied
    case prompt
}

extension PermissionKind {
    /// The name the Permissions API uses for this kind, or nil when no query name stands for it (`other`).
    public var permissionsAPIName: String? {
        switch self {
        case .camera: "camera"
        case .microphone: "microphone"
        case .geolocation: "geolocation"
        case .notifications: "notifications"
        case .clipboard: "clipboard-read"
        case .midiSysex: "midi"
        case .storageAccess: "storage-access"
        case .windowManagement: "window-management"
        case .localFonts: "local-fonts"
        case .screenCapture: "display-capture"
        case .other: nil
        }
    }

    /// The kind a Permissions API query names, or nil when Bow has nothing to answer it with, so the engine
    /// wiring leaves that query to the engine's own default. `midi` is the sysex kind only when the query asks
    /// for sysex; plain midi is nil because Bow stores no answer for it. `clipboard-write` and `push` are nil by
    /// choice: Bow stores no answer for them and the research does not say what Arc reports.
    public init?(permissionsAPIName name: String, sysex: Bool = false) {
        switch name {
        case "camera": self = .camera
        case "microphone": self = .microphone
        case "geolocation": self = .geolocation
        case "notifications": self = .notifications
        case "clipboard-read": self = .clipboard
        case "midi":
            guard sysex else { return nil }
            self = .midiSysex
        case "storage-access": self = .storageAccess
        case "window-management": self = .windowManagement
        case "local-fonts": self = .localFonts
        case "display-capture": self = .screenCapture
        default: return nil
        }
    }
}

extension SitePermissionStore {
    /// What a page at `url` reads for `kind`: granted for a remembered allow, denied for a remembered block,
    /// otherwise prompt. A page with no web origin, and a kind that is never remembered, read prompt. This
    /// matches Chromium: a blocked site reads denied, and screen sharing always asks.
    public func state(of kind: PermissionKind, on url: URL?) -> PermissionState {
        guard kind.isRemembered, let site = url.flatMap(PermissionSite.init(url:)) else { return .prompt }
        switch setting(for: kind, on: site) {
        case .allow: return .granted
        case .block: return .denied
        case nil: return .prompt
        }
    }
}
