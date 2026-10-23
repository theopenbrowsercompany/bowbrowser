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

    /// True while the pages of tabs that closed stay alive, out of sight, until their downloads end (destroying a
    /// page cancels its downloads). Quitting closes them, which cancels the downloads. Defaults to false.
    var keepsClosedTabsForDownloads: Bool { get }

    /// Returns once no closed tab's page is kept for its downloads any more, at once when none is. Defaults to
    /// returning at once.
    func closedTabsForDownloadsReleased() async
}

extension BrowserEngine {
    public var keepsClosedTabsForDownloads: Bool { false }

    public func closedTabsForDownloadsReleased() async {}
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

    /// The profile's downloads. Always the same object for one profile.
    var downloads: any EngineDownloads { get }
}

/// One profile's downloads: every download started in the profile's tabs since the engine started, in creation
/// order, with controls for each. Without a delegate to choose destinations, downloads are refused.
@MainActor public protocol EngineDownloads: AnyObject {
    var profileID: ProfileID { get }
    /// The snapshots the engine pushed last, oldest first, without removed downloads.
    var items: [DownloadItem] { get }
    /// Receives the downloads' events and chooses destinations. Implementations hold it weakly.
    var delegate: (any EngineDownloadsDelegate)? { get set }

    /// Each does nothing when the download cannot take it now (see `DownloadItem.canPause` and the others).
    func pause(_ id: DownloadID)
    func resume(_ id: DownloadID)
    func cancel(_ id: DownloadID)
    /// Takes a finished download out of the list, sending `DownloadEvent.removed`. The file stays on disk.
    func remove(_ id: DownloadID)
}

/// Receives a profile's download events on the main actor, in the order the engine produced them.
@MainActor public protocol EngineDownloadsDelegate: AnyObject {
    func downloads(_ downloads: any EngineDownloads, didReceive event: DownloadEvent)

    /// Asked once for each new download, after `created`: the file URL to save it to, or nil to cancel it.
    func downloads(
        _ downloads: any EngineDownloads,
        destinationFor item: DownloadItem,
        suggestedName: String
    ) async -> URL?

    /// Asked before a download starts, synchronously. Defaults to true; false refuses it with no events.
    func downloads(_ downloads: any EngineDownloads, shouldAllowDownloadFrom url: URL) -> Bool
}

extension EngineDownloadsDelegate {
    public func downloads(_ downloads: any EngineDownloads, shouldAllowDownloadFrom url: URL) -> Bool {
        true
    }
}

/// One web page for its whole life, independent of any view that shows it.
@MainActor public protocol EngineTab: AnyObject {
    var tabID: TabID { get }
    var profileID: ProfileID { get }

    /// The snapshot the engine pushed last, also delivered as `TabEvent.stateChanged`.
    var state: EngineTabState { get }

    /// True once the page has been destroyed, whoever closed it. Navigation calls then do nothing.
    var isClosed: Bool { get }

    /// Why the tab closed: set once it has, before `TabEvent.closed` arrives, and nil while it is open or after it
    /// was unloaded. Defaults to nil (the engine does not say).
    var closeReason: TabCloseReason? { get }

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

    /// Destroys the page's browser to free its memory while the app keeps the tab's model, to load it again later
    /// in a new tab. The page's beforeunload handler runs, but it never prompts: a page that would ask to stay
    /// keeps the tab loaded and this returns false. Returns true once unloaded; the tab is then closed and its
    /// last event is `TabEvent.unloaded`, not `closed`. Defaults to false (the engine cannot unload).
    func unload() async -> Bool

    /// The page's zoom level: 0 is 100%, and each step of 1 is 20% larger (negative is smaller). The engine
    /// remembers zoom per site in the profile, so setting it changes every tab on the same site, now and later.
    var zoomLevel: Double { get }
    /// Sets the zoom level of the page's site (see `zoomLevel`). Defaults to doing nothing.
    func setZoomLevel(_ level: Double)

    /// Opens DevTools for the page in a window of its own, inspecting the element at `point` when given (and only
    /// focusing it when it is open already). DevTools closes with the tab, and quitting closes it. Does nothing once
    /// the tab is closed. Defaults to doing nothing.
    func showDevTools(inspectingAt point: PagePoint?)
    /// Closes the page's DevTools, if open. Defaults to doing nothing.
    func closeDevTools()
    /// True while the page's DevTools is open. Defaults to false.
    var hasDevTools: Bool { get }
}

extension EngineTab {
    public var closeReason: TabCloseReason? { nil }
    public func unload() async -> Bool { false }
    public var zoomLevel: Double { 0 }
    public func setZoomLevel(_ level: Double) {}
    public func showDevTools(inspectingAt point: PagePoint?) {}
    public func closeDevTools() {}
    public var hasDevTools: Bool { false }
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

    /// The page is opening a new page (a link with a target, `window.open`): where it goes, decided synchronously.
    /// Defaults to `.window`, the engine's own popup window, which keeps `window.opener`. Popups opened by popups
    /// and links saved to disk are not asked about.
    func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision

    /// A popup decided as `.foregroundTab`, `.backgroundTab` or `.popupPanel` arrived as a new tab in the same profile, still
    /// connected to its opener (`window.opener`). The app owns it from now on. Asked at once, right after
    /// `decidePopup` and before the new tab's first navigation, so the app's navigation policy covers that too: take
    /// the tab, but show no modal UI and do not close the opener here. Defaults to closing it.
    func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest)

    /// A key event is about to reach the page; true claims it, so the page never sees it. Asked synchronously.
    /// Claiming a key down also claims the character and key up of the same press. Defaults to false.
    func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool

    /// A server asked for a user name and password. Answer with credentials, or nil to cancel (the page then
    /// shows the server's own 401 page). Defaults to nil.
    func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials?

    /// The page's certificate failed to verify. Defaults to `.cancel`, which fails the navigation and shows the
    /// engine's error page.
    func tab(_ tab: any EngineTab, decideCertificateError error: CertificateError) async -> CertificateErrorDecision

    /// The page asked for an alert, confirm or prompt (never its "leave this site?" prompt, which the engine asks
    /// itself). The answer may take as long as the person needs; the page waits for it. Defaults to `.cancelled`.
    func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer

    /// The person asked for a context menu in the page: what to show (see `ContextMenus.swift`). Asked on a later
    /// main thread task than the engine's callback, synchronously. Defaults to `.engineDefault`, the engine's own
    /// menu.
    func tab(_ tab: any EngineTab, decideContextMenu request: ContextMenuRequest) -> ContextMenuDecision

    /// The person chose `command` from a menu the app showed for `request`: true when the app ran it itself, false
    /// to leave it to the engine (`ContextMenuCommand` says what the engine does with each). Not asked when the page
    /// moved to another address or closed while the menu was open; the choice then drops. Defaults to false.
    func tab(
        _ tab: any EngineTab, runContextMenuCommand command: ContextMenuCommand, request: ContextMenuRequest
    ) -> Bool
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        .dismiss
    }

    public func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        .allow
    }
}
