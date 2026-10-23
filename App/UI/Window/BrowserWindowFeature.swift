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

    /// `tab`, one of the window's tabs, reported `event`. The window has already updated its tab list.
    func tab(_ tab: any EngineTab, didReceive event: TabEvent)

    /// `tab` closed and is about to leave the window's tab list, so its entry can still be looked up.
    func tabDidClose(_ tab: any EngineTab)

    /// The window created `tab`, the engine tab of sidebar item `item`, in the profile of the Space that holds it.
    /// Called for every engine tab the window creates: a new tab, and a saved tab loading when it is first selected.
    func tabOpened(_ tab: any EngineTab, item: SidebarItemID)

    /// `space` came on screen in the window (also once when the window opens). Its tabs are now the window's tabs.
    func activeSpaceChanged(_ space: SidebarSpace)

    /// The window's sidebar store committed a change; `graph` is the committed sidebar. Called after the window has
    /// updated its own tabs from it.
    func storeChanged(_ graph: SidebarGraph)

    /// The answer to a permission request from `tab`, or nil to leave it to another feature. The first feature that
    /// answers decides; with none, the request is dismissed.
    func decidePermission(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision?
}

extension BrowserWindowFeature {
    static func addMenuItems(to menus: MainMenu.Menus) {}
    func selectedTabChanged(_ tab: (any EngineTab)?) {}
    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {}
    func tabDidClose(_ tab: any EngineTab) {}
    func tabOpened(_ tab: any EngineTab, item: SidebarItemID) {}
    func activeSpaceChanged(_ space: SidebarSpace) {}
    func storeChanged(_ graph: SidebarGraph) {}
    func decidePermission(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision? { nil }
}
