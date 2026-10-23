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
    /// app arrives. Returns the Little Arc window it opened, or nil when it opened none. With no browser window open,
    /// the page's own calls go through the test's last window, closed or not.
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
    /// The open browser window whose Space on screen shows `littleArcPage` as its shown tab, as a person sees it, and
    /// whether it stays off every screen; nil when no open window shows it. A window Open in Bow opened with no
    /// browser window open is found here too.
    func browserWindow(showing littleArcPage: any E2EPage) throws -> (state: E2EBrowserWindowState, offScreen: Bool)?
    /// The page dialog up as a sheet on Little Arc window `window`, nil when none is.
    func littleArcDialog(in window: E2ELittleArcWindow) throws -> E2EPageDialog?
    /// True when Little Arc window `window` and the dialog sheet on it both stay off every screen.
    func littleArcDialogIsOffScreen(in window: E2ELittleArcWindow) throws -> Bool
    /// Presses OK (true) or Cancel (false) on the dialog sheet of Little Arc window `window`, as a person does.
    func answerLittleArcDialog(in window: E2ELittleArcWindow, accept: Bool) throws
    /// The permission prompt anchored to Little Arc window `window`'s page, nil when none shows.
    func littleArcPermissionPrompt(in window: E2ELittleArcWindow) throws -> E2EPermissionPrompt?
    /// Chooses the main menu item whose shortcut is `key` with exactly `modifiers` as AppKit sends it while Little Arc
    /// window `window` is key and the browser window is main: the first object that handles it along Little Arc's
    /// responder chain and its delegate, then along the browser window's, once it validates. Returns the class of the
    /// object that took it, or "disabled" when that object refused it, or "none" when nothing handles it.
    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, inLittleArc window: E2ELittleArcWindow) throws
        -> String
    /// Little Arc window `window`'s address: whether it is being edited (it has the keyboard focus in its window) and
    /// the text it shows.
    func littleArcAddress(in window: E2ELittleArcWindow) throws -> (isEditing: Bool, text: String)
    /// What the app would do now if its last browser window had just closed (stay, quit or wait for downloads),
    /// decided as the real handler decides it, without the e2e run's own "never quit".
    func lastWindowClosedDecision() throws -> String
    /// What the app decided when a Little Arc window last closed as its last window (stay, quit or wait for
    /// downloads), as the real close path decides it and without acting on it, or "none" when no Little Arc window
    /// has closed as the last window since the previous call or the previous test's end. Reading clears it.
    func takeLittleArcClosedDecision() throws -> String
    /// Orders the run's shared downloads window out, so a test can leave the app with no window at all (an open
    /// downloads window keeps the app running, as any window does). Returns whether one was shown.
    func hideDownloadsWindow() throws -> Bool
    /// Orders the downloads window `hideDownloadsWindow` hid back in, off screen.
    func showDownloadsWindow() throws
    /// Makes the next move of Little Arc window `window`'s page fail after its window switched Space, as a window
    /// refusing the page would.
    func failNextLittleArcAdopt(in window: E2ELittleArcWindow) throws
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
