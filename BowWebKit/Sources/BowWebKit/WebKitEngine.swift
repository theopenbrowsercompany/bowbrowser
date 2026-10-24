import BowCore
import Foundation
import WebKit

/// Bow's engine on the system WebKit. Each profile is one `WKWebsiteDataStore`: a persistent profile's is the store
/// WebKit keeps on disk under the profile's storage UUID (`ProfileRef.storeID`), an ephemeral one's lives in memory,
/// so no two profiles ever share cookies, logins or site data. WebKit's default store belongs to no profile and is
/// never used.
@MainActor
public final class WebKitEngine: BrowserEngine {
    /// The profiles in the order they were made, the default first.
    private var profiles: [WebKitProfile]
    /// True once `quit()` has started.
    private(set) var hasQuit = false

    /// An engine whose default profile is `defaultProfile`: the app's default profile record's `ref`, so its storage
    /// UUID names the default profile's store as it names every other's. The default profile never goes through
    /// `createProfile(_:)`, and this is how the engine learns its UUID; it must carry `ProfileID.default` and be
    /// persistent, as the default profile always is.
    public init(defaultProfile: ProfileRef) {
        precondition(defaultProfile.engineID == .default, "the default profile's engine ID is ProfileID.default")
        precondition(defaultProfile.isPersistent, "the default profile is persistent")
        profiles = [WebKitProfile(defaultProfile)]
    }

    /// Creates the profile `ref` names on its own store (`WebKitProfile.store(for:)`). Throws
    /// `EngineError.invalidProfileID` when the engine ID cannot name a folder, and `EngineError.profileExists` when
    /// the ID is taken (ignoring case, the default's included) or when `ref` is persistent and another persistent
    /// profile already has its storage UUID, since the two would share one store.
    public func createProfile(_ ref: ProfileRef) throws -> any EngineProfile {
        let id = ref.engineID
        guard id.isValid else { throw EngineError.invalidProfileID(id) }
        guard !profiles.contains(where: { $0.profileID.rawValue.caseInsensitiveCompare(id.rawValue) == .orderedSame })
        else { throw EngineError.profileExists(id) }
        guard !ref.isPersistent || !profiles.contains(where: { $0.isPersistent && $0.storeID == ref.storeID })
        else { throw EngineError.profileExists(id) }
        let profile = WebKitProfile(ref)
        profiles.append(profile)
        return profile
    }

    /// The profile with exactly this ID, or nil; `ProfileID.default` always returns the default profile.
    public func profile(id: ProfileID) -> (any EngineProfile)? {
        profiles.first { $0.profileID == id }
    }

    /// Closes every open tab of every profile, then returns. WebKit has no engine to stop: each web view's web
    /// content process ends once its web view is gone. Calling it again closes any tab made since.
    public func quit() async {
        hasQuit = true
        for profile in profiles {
            for tab in profile.openTabs { _ = await tab.close() }
        }
    }

    /// The profiles in the order they were made, the default first.
    var allProfiles: [WebKitProfile] { profiles }
}
