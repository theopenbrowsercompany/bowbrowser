import Foundation

// The contract between app logic and the browser engine. App code and its tests talk only to these
// protocols, so they never need CEF: the app uses an adapter over the Objective-C bridge, and tests
// use the mock in BowCoreTestSupport. Everything is value based and pushed by the engine, so an
// engine running in another process stays possible.

/// The running browser engine: owns the profiles and shuts everything down.
@MainActor public protocol BrowserEngine: AnyObject {
    /// Creates a profile with its own isolated storage. Persistent profiles keep cookies, cache and
    /// site data on disk; ephemeral ones keep them in memory and lose them when closed.
    /// Throws `EngineError.invalidProfileID` when the ID cannot name a folder (see
    /// `ProfileID.isValid`), and `EngineError.profileExists` when
    /// the ID is taken, ignoring case, since folder names on macOS volumes ignore case by default.
    func createProfile(id: ProfileID, isPersistent: Bool) throws -> any EngineProfile

    /// Returns the profile with this ID, or nil. `ProfileID.default` always returns a profile.
    func profile(id: ProfileID) -> (any EngineProfile)?

    /// Shuts the engine down. Returns once every tab is closed and the engine has stopped.
    func quit() async
}

/// One isolated storage profile (one per space).
@MainActor public protocol EngineProfile: AnyObject {
    var profileID: ProfileID { get }
    var isPersistent: Bool { get }

    /// Creates a tab in this profile and starts loading `url`. The tab ID is assigned now; state
    /// and navigation events follow through the tab's delegate.
    func createTab(url: URL) -> any EngineTab

    /// Stores a remembered permission answer in the engine's own settings for this profile (its content
    /// settings), so the engine's permission checks agree with the app: a page querying its permission state sees
    /// it, and the engine does not ask again for a kind already answered. The app's `SitePermissionStore` stays the
    /// record the app reads.
    func setPermission(_ setting: SitePermissionSetting, for kind: PermissionKind, on site: PermissionSite)
}

/// One web page for its whole life, independent of any view that shows it.
@MainActor public protocol EngineTab: AnyObject {
    var tabID: TabID { get }
    var profileID: ProfileID { get }

    /// The snapshot the engine pushed last, also delivered as `TabEvent.stateChanged`.
    var state: EngineTabState { get }

    /// True once the page has been destroyed, whoever closed it. Navigation calls then do nothing.
    var isClosed: Bool { get }

    /// Receives the tab's events. Implementations hold it weakly.
    var delegate: (any EngineTabDelegate)? { get set }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stop()

    /// Finds `text` in the page, highlighting every match and selecting the active one. Asking again
    /// with the same text and case steps to the next match (the previous one when `forward` is
    /// false); other text starts a new search, and empty text stops finding. Results arrive as
    /// `TabEvent.findResult`.
    func find(_ text: String, forward: Bool, matchCase: Bool)

    /// Stops finding and clears the highlights; the active match stays selected. Results of the
    /// stopped search that arrive later are dropped.
    func stopFind()

    /// Closes the tab after running the page's beforeunload handler. Returns true when the tab
    /// closed (at once when it already had) and false when the page (or the person, at its prompt)
    /// kept it open. A tab that closes also sends `TabEvent.closed`, which may come before or after
    /// this returns (the mock sends it first, the CEF engine on a later main thread task).
    func close() async -> Bool
}

/// Receives a tab's events on the main actor, in the order the engine produced them.
@MainActor public protocol EngineTabDelegate: AnyObject {
    func tab(_ tab: any EngineTab, didReceive event: TabEvent)

    /// Asked before every main frame navigation, synchronously. Defaults to `.allow`.
    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy

    /// The page asked to use something that needs the person's permission (camera, microphone, location,
    /// notifications, clipboard and others). The answer covers every kind in the request and may take as long as
    /// the person needs. Defaults to `.dismiss`, which grants nothing.
    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        .dismiss
    }

    public func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        .allow
    }
}
