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
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        .allow
    }
}
