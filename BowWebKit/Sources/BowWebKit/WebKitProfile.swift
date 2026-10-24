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
    /// Every tab made on the profile, held weakly: whoever holds a tab keeps it, and quitting closes those still
    /// open (see `register(_:)`).
    private var registered: [WeakTab] = []

    /// A profile over `store`, which the engine makes from the profile's `ProfileRef`.
    init(profileID: ProfileID, storeID: UUID, isPersistent: Bool, store: WKWebsiteDataStore) {
        self.profileID = profileID
        self.storeID = storeID
        self.isPersistent = isPersistent
        self.store = store
        downloads = WebKitDownloads(profileID: profileID)
    }

    /// The profile `ref` names, on its own store (see `store(for:)`).
    convenience init(_ ref: ProfileRef) {
        self.init(
            profileID: ref.engineID, storeID: ref.storeID, isPersistent: ref.isPersistent, store: Self.store(for: ref))
    }

    /// The data store `ref` names. A persistent profile's store is the one WebKit keeps on disk under its storage
    /// UUID, so the profile reaches the same cookies and site data on every launch and never another profile's; an
    /// ephemeral profile gets a new store in memory, which keeps nothing once its last web view is gone. Never
    /// WebKit's default store, which no Bow profile owns.
    static func store(for ref: ProfileRef) -> WKWebsiteDataStore {
        ref.isPersistent ? WKWebsiteDataStore(forIdentifier: ref.storeID) : .nonPersistent()
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

    /// True once the engine began quitting. The profile then refuses new tabs: `createTab` returns a tab that is
    /// already closed with `.quit`, so a delegate that opens a tab on every close cannot keep quitting going.
    private(set) var isQuitting = false

    /// Begins quitting: from now on every new tab is refused (see `isQuitting`).
    func beginQuit() {
        isQuitting = true
    }

    /// Records `tab` as one of the profile's, so quitting closes it. A tab calls this as it is made, whichever way it
    /// is made (restoring an unloaded tab and opening a popup too); a second call does nothing.
    func register(_ tab: WebKitTab) {
        registered.removeAll { $0.tab == nil || $0.tab?.isClosed == true }
        guard !registered.contains(where: { $0.tab === tab }) else { return }
        registered.append(WeakTab(tab))
    }

    /// The profile's tabs that are still open, in the order they were made.
    var openTabs: [WebKitTab] {
        registered.compactMap(\.tab).filter { !$0.isClosed }
    }

    /// Does nothing: Bow's own permission store is the only record of a site's permissions, and the tab answers
    /// WebKit's permission questions from it, so WebKit keeps no answers of its own to agree with.
    func setPermission(_ setting: SitePermissionSetting, for kind: PermissionKind, on site: PermissionSite) {}
}

/// A tab held weakly.
@MainActor
private struct WeakTab {
    weak var tab: WebKitTab?

    init(_ tab: WebKitTab) {
        self.tab = tab
    }
}
