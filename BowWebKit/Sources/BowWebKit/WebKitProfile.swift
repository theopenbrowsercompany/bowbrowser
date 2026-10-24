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
    /// The profile's downloads, which hold every download its tabs began (see `WebKitDownloads`).
    let webKitDownloads: WebKitDownloads
    var downloads: any EngineDownloads { webKitDownloads }
    /// Every tab made on the profile, held weakly: whoever holds a tab keeps it, and quitting closes those still
    /// open (see `register(_:)`).
    private var registered: [WeakTab] = []

    /// A profile over `store`, which the engine makes from the profile's `ProfileRef`.
    init(profileID: ProfileID, storeID: UUID, isPersistent: Bool, store: WKWebsiteDataStore) {
        self.profileID = profileID
        self.storeID = storeID
        self.isPersistent = isPersistent
        self.store = store
        webKitDownloads = WebKitDownloads(profileID: profileID, store: store)
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
    ///
    /// Scripts may open windows without a user gesture, so WebKit's own popup blocker stays out of the way and the
    /// tab is asked about every new page, with whether a click or key opened it (`WebKitSPI.isUserInitiated`); Bow's
    /// popup rules then decide a request with no gesture (`PopupPolicy.noGestureDecision`), as on Chromium. Only when
    /// WebKit cannot say whether a request had a gesture does its blocker stay on, refusing such a `window.open`
    /// (null) before asking the tab, which is the answer those rules give.
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = WebKitSPI.readsUserGesture
        return configuration
    }

    func createTab(url: URL) -> any EngineTab {
        let tab = WebKitTab(profile: self)
        tab.load(url)
        return tab
    }

    /// A tab for a page another tab of this profile opened, on the configuration WebKit passed for it (a copy of the
    /// opener's, on this profile's store), which keeps the new page's `window.opener`; WebKit loads its first page.
    /// It goes through the same init as every tab, so it registers with the profile and quitting closes it, and a
    /// profile that is quitting gives a tab already closed with `.quit` and no web view.
    func createTab(configuration: WKWebViewConfiguration) -> WebKitTab {
        // WebKit's own copy of the opener's configuration, so always on this store; checked in Debug only, since a
        // trap here would end the app inside WebKit's callback.
        assert(configuration.websiteDataStore === store, "a popup's configuration is on its opener's store")
        return WebKitTab(profile: self, configuration: configuration)
    }

    /// True once the engine began quitting. The profile then refuses new tabs: `createTab` returns a tab that is
    /// already closed with `.quit`, so a delegate that opens a tab on every close cannot keep quitting going.
    private(set) var isQuitting = false

    /// Begins quitting: from now on every new tab and download is refused (see `isQuitting`), and every download
    /// that has not ended is cancelled.
    func beginQuit() {
        isQuitting = true
        webKitDownloads.cancelAll()
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
