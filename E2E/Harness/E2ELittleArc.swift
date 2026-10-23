import CoreGraphics
import Foundation

/// Little Arc as a test sees it: links from other apps delivered as GetURL Apple Events to the app's own handler,
/// the Little Arc windows they open, and the browser window a Little Arc page moves into.
/// E2E/Harness/E2EAppAdapter+LittleArc.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2ELittleArcApp: E2EApp {
    /// Sets "links from other apps open in Little Arc": true or false, or nil for never set (the app's default).
    /// The setting goes back to off (the e2e run's own value, which the other link tests rely on) when the test ends.
    func setLittleArcSetting(_ value: Bool?) throws
    /// Delivers `url` as a GetURL Apple Event sent from this app to its own handler, the way a link clicked in another
    /// app arrives. Returns the Little Arc window it opened, or nil when it opened none.
    func deliverLinkToLittleArc(_ url: URL) throws -> E2ELittleArcWindow?
    /// The open Little Arc windows, oldest first, as they are now.
    func littleArcWindows() throws -> [E2ELittleArcWindowState]
    /// Presses `key` with `modifiers` in Little Arc window `window`, the way AppKit hands a key window its key
    /// equivalents (before its page or the menu bar). Returns whether Little Arc took the key.
    func pressKey(_ key: String, modifiers: E2EKeyModifiers, inLittleArc window: E2ELittleArcWindow) throws -> Bool
    /// Clicks the close button of Little Arc window `window` (the page's leave prompt is asked first).
    func closeLittleArc(_ window: E2ELittleArcWindow) throws
    /// Returns once no Little Arc window is open, or throws shortly before the step's limit.
    func untilNoLittleArc() async throws
    /// The browser window of `page` as a person sees it: its tabs, the shown tab, the Space on screen.
    func browserWindowState(of page: any E2EPage) throws -> E2EBrowserWindowState
    /// The title of the Space of `page`'s window that holds `littleArcPage` as a tab, or nil when none does.
    func spaceTitle(holding littleArcPage: any E2EPage, in page: any E2EPage) throws -> String?
    /// How many browsers the engine has open or is creating, popups and Little Arc pages included.
    var openBrowsers: Int { get }
}

/// A Little Arc window a link opened, with the page it shows.
@MainActor
struct E2ELittleArcWindow {
    /// The window's number, which names it while it is open.
    var windowNumber: Int
    /// Little Arc's page. Its window, for the page's own calls, is the browser window it can move into.
    var page: any E2EPage
}

/// A Little Arc window as it is now.
struct E2ELittleArcWindowState: Equatable {
    var windowNumber: Int
    /// True for a floating panel (an `NSPanel` at the floating window level) that joins the macOS Space in use.
    var isFloatingPanel: Bool
    /// True when the window is key or overlaps any screen; an e2e window must never.
    var intrudes: Bool
    var frame: CGRect
    /// The compact toolbar: the host it shows, whether Open in Bow is enabled, and the move menu's Space items.
    var toolbarHost: String
    var openEnabled: Bool
    var moveSpaces: [String]
    /// True while the window's own web view shows its page.
    var showsPage: Bool
}

/// A browser window as a person sees it, to compare before and after something that must leave it alone.
struct E2EBrowserWindowState: Equatable, CustomStringConvertible {
    /// Each listed tab's runtime ID and address, in sidebar order.
    var tabs: [String]
    /// The runtime ID of the shown tab, or "none".
    var shownTab: String
    var spaceTitle: String
    var frame: CGRect
    var isKey: Bool

    var description: String { "tabs=\(tabs.count) shown=\(shownTab) space=\(spaceTitle) key=\(isKey)" }
}
