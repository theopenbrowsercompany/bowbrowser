import BowCore
import Foundation
import WebKit

/// One Bow profile over one `WKWebsiteDataStore`: every tab made here has a web view on that store, so the
/// profile's cookies and site data are its own.
@MainActor
final class WebKitProfile: EngineProfile {
    let profileID: ProfileID
    /// The profile's storage UUID (`ProfileRef.storeID`), which names a persistent store on disk.
    let storeID: UUID
    let isPersistent: Bool
    let store: WKWebsiteDataStore
    let downloads: any EngineDownloads

    /// A profile over `store`, which the engine makes from the profile's `ProfileRef`.
    init(profileID: ProfileID, storeID: UUID, isPersistent: Bool, store: WKWebsiteDataStore) {
        self.profileID = profileID
        self.storeID = storeID
        self.isPersistent = isPersistent
        self.store = store
        downloads = WebKitDownloads(profileID: profileID)
    }

    /// A fresh configuration for one tab's web view, on the profile's store. Each web view gets its own, since a
    /// web view keeps the configuration it was made with.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        return configuration
    }

    func createTab(url: URL) -> any EngineTab {
        let tab = WebKitTab(profile: self)
        tab.load(url)
        return tab
    }

    /// Does nothing: Bow's own permission store is the only record of a site's permissions, and the tab answers
    /// WebKit's permission questions from it, so WebKit keeps no answers of its own to agree with.
    func setPermission(_ setting: SitePermissionSetting, for kind: PermissionKind, on site: PermissionSite) {}
}
