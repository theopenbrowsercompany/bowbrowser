import AppKit
import BowCore

/// One feature of a browser window (navigation, find, permissions, the sidebar), in its own file under
/// `App/UI/Window/` and listed in `WindowFeatures.all`.
///
/// The window creates one of each when it opens and puts them in its responder chain right after itself, so a
/// feature handles its own menu commands (`@objc` actions) and validates them (`NSMenuItemValidation`). Its menu
/// items come from `addMenuItems(to:)`, with nil targets, so they reach the key window's feature through the chain.
/// Everything else it learns from the calls below; the window core never calls a feature by name.
@MainActor
protocol BrowserWindowFeature: NSResponder {
    /// Called once per window, while the window opens and before its first tab does. `window` owns the feature.
    init(window: BrowserWindowController)

    /// Adds the feature's items to the app's menus. Called once, when the menu bar is built.
    static func addMenuItems(to menus: MainMenu.Menus)

    /// The window showed `tab`: the selected tab changed, or the tab list did (a tab opened or closed). Nil once the
    /// window's last tab has closed.
    func selectedTabChanged(_ tab: (any EngineTab)?)

    /// The person dragged a divider between the panes the window shows (`BrowserWindowController.showPanes`);
    /// `fractions` is each pane's new share of the page area's width, in pane order.
    func paneDividerMoved(fractions: [Double])

    /// `tab`, one of the window's tabs, reported `event`. The window has already updated its tab list.
    func tab(_ tab: any EngineTab, didReceive event: TabEvent)

    /// `tab` closed and is about to leave the window's tab list, so its entry can still be looked up.
    func tabDidClose(_ tab: any EngineTab)

    /// The window created `tab`, the engine tab of sidebar item `item`, in the profile of the Space that holds it.
    /// Called for every engine tab the window creates: a new tab, and a saved tab loading when it is first selected.
    func tabOpened(_ tab: any EngineTab, item: SidebarItemID)

    /// `space` came on screen in the window (also once when the window opens). Its tabs are now the window's tabs.
    func activeSpaceChanged(_ space: SidebarSpace)

    /// The person asked the window to close. A feature that shows a page of its own (a Peek) returns the close of that
    /// page, running its leave prompt: the window waits for it and closes its tabs only when it returns true, and
    /// stays open, unchanged, when the person stays. Nil when the feature has no page to ask. Asked synchronously.
    func closeBeforeWindow() -> Task<Bool, Never>?

    /// The window's sidebar store committed a change; `graph` is the committed sidebar. Called after the window has
    /// updated its own tabs from it.
    func storeChanged(_ graph: SidebarGraph)

    /// The window tried to enter macOS full screen and stayed out (`NSWindowDelegate`; AppKit posts no notification
    /// for it). Its `willEnterFullScreenNotification` came first, and no did enter notification follows.
    func windowDidFailToEnterFullScreen()

    /// The window tried to leave macOS full screen and stayed in (`NSWindowDelegate`; AppKit posts no notification
    /// for it). Its `willExitFullScreenNotification` came first, and no did exit notification follows.
    func windowDidFailToExitFullScreen()

    /// The answer to a permission request from `tab`, or nil to leave it to another feature. The first feature that
    /// answers decides; with none, the request is dismissed.
    func decidePermission(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision?

    // The engine hooks below reach a feature only for the window's own tabs. For each, the first feature (in
    // `WindowFeatures.all` order) that answers decides, and with none the window keeps the engine contract's default.

    /// Whether `tab`'s main frame may go to `navigation`, or nil to leave it to another feature. Asked synchronously
    /// before every main frame navigation, after the window's own `navigationPolicy` (whose `.cancel` wins). With no
    /// answer the navigation goes ahead. A feature that cancels may open the address elsewhere (a Peek).
    func decideNavigation(_ navigation: EngineNavigation, for tab: any EngineTab) -> NavigationPolicy?

    /// Where a new page `tab` opens goes (`request` carries the click modifiers), or nil to leave it to another
    /// feature. Asked synchronously. With no answer the engine opens its own popup window.
    func decidePopup(_ request: PopupRequest, from tab: any EngineTab) -> PopupDecision?

    /// A popup decided as a tab arrived as `newTab`, still connected to its opener `tab`. True takes ownership of it
    /// (usually through `BrowserWindowController.adoptTab(_:after:placement:select:url:)`); with no taker it closes.
    /// Asked synchronously, before the new tab's first navigation: show no modal UI and do not close the opener here.
    func didOpenPopup(_ newTab: any EngineTab, from tab: any EngineTab, request: PopupRequest) -> Bool

    /// A key event is about to reach `tab`'s page; true claims it, so the page never sees it. Asked synchronously.
    /// Claim keys through `KeyShortcuts.shortcut(for:claimedBy:)`, so every claimed key is listed in one place.
    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool

    /// Credentials for a server's sign in request from `tab`, or nil to leave it to another feature. With no answer
    /// the sign in is cancelled.
    func answer(_ challenge: AuthChallenge, for tab: any EngineTab) async -> AuthCredentials?

    /// What to do with a certificate that failed to verify in `tab`, or nil to leave it to another feature. With no
    /// answer the load is cancelled and the engine shows its error page.
    func decideCertificateError(_ error: CertificateError, for tab: any EngineTab) async -> CertificateErrorDecision?

    /// The answer to an alert, confirm or prompt from `tab`'s page, or nil to leave it to another feature. With no
    /// answer the dialog is cancelled. It may take as long as the person needs.
    func runDialog(_ dialog: PageDialog, for tab: any EngineTab) async -> PageDialogAnswer?

    /// What the context menu `tab`'s page asked for shows, or nil to leave it to another feature. Asked
    /// synchronously. With no answer the window shows Bow's own menu (`ContextMenuPolicy.defaultDecision(for:)`).
    func decideContextMenu(_ request: ContextMenuRequest, for tab: any EngineTab) -> ContextMenuDecision?

    /// The person chose `command` from the menu shown for `request` in `tab`; true means the feature ran it. With
    /// no taker the engine runs it (`ContextMenuCommand` says how; Open Link in New Tab and custom items then do
    /// nothing). Asked synchronously.
    func runContextMenuCommand(_ command: ContextMenuCommand, request: ContextMenuRequest, in tab: any EngineTab)
        -> Bool

    /// New Tab was chosen (File > New Tab, Cmd+T through the menu, the sidebar's New Tab button); true means the
    /// feature handled it (the command bar, for example). With no taker the window opens `newTabURL` in a new tab.
    func handleNewTab(_ sender: Any?) -> Bool
}

extension BrowserWindowFeature {
    static func addMenuItems(to menus: MainMenu.Menus) {}
    func selectedTabChanged(_ tab: (any EngineTab)?) {}
    func paneDividerMoved(fractions: [Double]) {}
    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {}
    func tabDidClose(_ tab: any EngineTab) {}
    func tabOpened(_ tab: any EngineTab, item: SidebarItemID) {}
    func activeSpaceChanged(_ space: SidebarSpace) {}
    func closeBeforeWindow() -> Task<Bool, Never>? { nil }
    func storeChanged(_ graph: SidebarGraph) {}
    func windowDidFailToEnterFullScreen() {}
    func windowDidFailToExitFullScreen() {}
    func decidePermission(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision? { nil }
    func decideNavigation(_ navigation: EngineNavigation, for tab: any EngineTab) -> NavigationPolicy? { nil }
    func decidePopup(_ request: PopupRequest, from tab: any EngineTab) -> PopupDecision? { nil }
    func didOpenPopup(_ newTab: any EngineTab, from tab: any EngineTab, request: PopupRequest) -> Bool { false }
    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool { false }
    func answer(_ challenge: AuthChallenge, for tab: any EngineTab) async -> AuthCredentials? { nil }
    func decideCertificateError(_ error: CertificateError, for tab: any EngineTab) async -> CertificateErrorDecision? {
        nil
    }
    func runDialog(_ dialog: PageDialog, for tab: any EngineTab) async -> PageDialogAnswer? { nil }
    func decideContextMenu(_ request: ContextMenuRequest, for tab: any EngineTab) -> ContextMenuDecision? { nil }
    func runContextMenuCommand(_ command: ContextMenuCommand, request: ContextMenuRequest, in tab: any EngineTab)
        -> Bool
    { false }
    func handleNewTab(_ sender: Any?) -> Bool { false }
}
