import AppKit
import BowCore

// The BowCore engine contract over the Objective-C bridge (BowEngine, BowProfile, BowTab). App code talks to the
// engine through the BowCore protocols only; this file and its CEF* siblings are where they meet the bridge: the
// tab in CEFTab.swift with one extension file per kind of delegate call, the value conversions in CEFValues.swift,
// and the AppKit seams the protocols leave out on purpose (showing a tab in a view, site icons) in CEFViews.swift.

/// The running Chromium engine as a `BrowserEngine`. Create it any time; use it once the engine has started
/// (`engineDidStart`), since it reaches the bridge's `BowEngine.shared` on each call.
@MainActor
final class CEFEngine: BrowserEngine {
    /// One adapter per bridge profile, keyed by the bridge's ID, so a profile always comes back as the same object.
    private var profiles: [String: CEFProfile] = [:]
    /// Callers of `quit()`. The process exits once the engine stops, so they are never resumed; they are kept
    /// rather than dropped so a quit a page cancels leaves its caller waiting for a later quit.
    private var quitWaiters: [CheckedContinuation<Void, Never>] = []

    private var bridge: BowEngine { .shared }

    func createProfile(id: ProfileID, isPersistent: Bool) throws -> any EngineProfile {
        do {
            return adapter(for: try bridge.createProfile(id: id.rawValue, persistent: isPersistent))
        } catch let error as BowEngineError {
            switch error.code {
            case .profileExists: throw EngineError.profileExists(id)
            case .invalidProfileID: throw EngineError.invalidProfileID(id)
            @unknown default: throw error
            }
        }
    }

    func profile(id: ProfileID) -> (any EngineProfile)? {
        bridge.profile(id: id.rawValue).map(adapter(for:))
    }

    /// Closes every tab, then stops the engine. On this engine the process exits once it has stopped, so the
    /// call does not return in practice. A page the person chooses to stay on cancels the quit, as quitting from
    /// the menu does, and the caller keeps waiting for a later quit.
    func quit() async {
        await withCheckedContinuation { continuation in
            quitWaiters.append(continuation)
            BowEngine.quit()
        }
    }

    private func adapter(for profile: BowProfile) -> CEFProfile {
        if let existing = profiles[profile.profileID] { return existing }
        let adapter = CEFProfile(profile)
        profiles[profile.profileID] = adapter
        return adapter
    }
}

/// One bridge profile as an `EngineProfile`.
@MainActor
final class CEFProfile: EngineProfile {
    private let profile: BowProfile

    init(_ profile: BowProfile) {
        self.profile = profile
    }

    var profileID: ProfileID { ProfileID(profile.profileID) }
    var isPersistent: Bool { profile.isPersistent }

    func createTab(url: URL) -> any EngineTab {
        CEFTab(profile.createTab(url: url))
    }

    func setPermission(_ setting: SitePermissionSetting, for kind: PermissionKind, on site: PermissionSite) {
        let kinds = BowPermissionRequest.Kind([kind])
        guard !kinds.isEmpty else { return }
        profile.setPermission(allowed: setting == .allow, kinds: kinds, origin: site.url)
    }

    private(set) lazy var downloads: any EngineDownloads = CEFDownloads(profile.downloads)
}
