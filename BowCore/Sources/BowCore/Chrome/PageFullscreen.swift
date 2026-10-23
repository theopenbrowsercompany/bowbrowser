import Foundation

/// A window's page fullscreen: a page that asked to fill the screen (a video's fullscreen button,
/// `element.requestFullscreen()`) gets the whole window, the way Arc and Chrome do it. The window's chrome (the
/// sidebar, or the top tabs bar) hides, the page card loses its inset, corners and shadow, and the window enters macOS
/// full screen unless it was there already. Escape, the page's own exit, leaving macOS full screen, switching tabs,
/// closing the tab or its page going away undo it, and the window leaves macOS full screen only if page fullscreen put
/// it there.
///
/// One value per window; each call returns what the window should do, in order.
public struct PageFullscreen: Equatable, Sendable {
    /// What the window does to follow page fullscreen.
    public enum Action: Equatable, Sendable {
        /// Hide the sidebar or the top tabs bar, and let the page card fill the window (`WindowChrome`).
        case hideChrome
        /// Bring the chrome and the page card back as the layout has them.
        case showChrome
        /// Enter or leave macOS full screen (`NSWindow.toggleFullScreen(_:)`).
        case toggleWindowFullScreen
        /// Ask the page of this tab to leave fullscreen (`EngineTab.exitFullscreen()`).
        case exitPage(TabID)
    }

    /// The tab whose page fills the window, or nil.
    public private(set) var tab: TabID?
    /// Whether page fullscreen put the window in macOS full screen, so leaving it takes the window back out.
    public private(set) var enteredWindowFullScreen = false

    public init() {}

    /// True while a page fills the window.
    public var isActive: Bool { tab != nil }

    /// `tab`'s page entered fullscreen. Only the shown tab's page takes the window: a page in a tab that is not shown
    /// is asked to leave at once. A second request from the page already filling the window changes nothing.
    public mutating func pageEntered(_ tab: TabID, isShown: Bool, windowIsFullScreen: Bool) -> [Action] {
        guard isShown else { return [.exitPage(tab)] }
        if self.tab == tab { return [] }
        if let other = self.tab {
            // Another page held the window (it cannot be shown any more): it leaves, the window stays as it is.
            self.tab = tab
            return [.exitPage(other)]
        }
        self.tab = tab
        enteredWindowFullScreen = !windowIsFullScreen
        return enteredWindowFullScreen ? [.hideChrome, .toggleWindowFullScreen] : [.hideChrome]
    }

    /// `tab`'s page left fullscreen on its own (Escape reached it through `exitPage`, `document.exitFullscreen()`,
    /// or its document went away).
    public mutating func pageExited(_ tab: TabID) -> [Action] {
        guard self.tab == tab else { return [] }
        return restore()
    }

    /// Escape was pressed in `tab`'s page: true when page fullscreen takes it (the page then leaves fullscreen and
    /// `pageExited` follows), false to let the key reach the page.
    public func claimsEscape(in tab: TabID) -> Bool {
        self.tab == tab
    }

    /// The window now shows `tab` (nil for none): a page that filled the window and is no longer shown leaves.
    public mutating func shownTabChanged(to tab: TabID?) -> [Action] {
        guard let current = self.tab, current != tab else { return [] }
        return [.exitPage(current)] + restore()
    }

    /// `tab` closed, unloaded or lost its render process: its page can no longer fill the window.
    public mutating func tabGone(_ tab: TabID) -> [Action] {
        guard self.tab == tab else { return [] }
        return restore()
    }

    /// The window left macOS full screen (the green button, View > Exit Full Screen, or page fullscreen's own exit).
    /// A page still filling the window leaves too; the window is already out, so it is not toggled again.
    public mutating func windowExitedFullScreen() -> [Action] {
        guard let current = tab else { return [] }
        tab = nil
        enteredWindowFullScreen = false
        return [.exitPage(current), .showChrome]
    }

    private mutating func restore() -> [Action] {
        let toggle = enteredWindowFullScreen
        tab = nil
        enteredWindowFullScreen = false
        return toggle ? [.showChrome, .toggleWindowFullScreen] : [.showChrome]
    }
}

/// Which chrome a window shows around the page card, and how the card sits: decided by the layout, View > Hide
/// Toolbar, and whether a page fills the window (`PageFullscreen`).
public struct WindowChrome: Equatable, Sendable {
    public var showsSidebar: Bool
    public var showsTopBar: Bool
    /// The card's corner radius and shadow: false when the page fills the window edge to edge.
    public var cardStyled: Bool

    public init(layout: WindowLayout, pageFullscreen: Bool) {
        showsSidebar = !pageFullscreen && layout == .sidebar
        showsTopBar = !pageFullscreen && layout == .topTabs
        cardStyled = !pageFullscreen
    }

    /// The page card's insets (top, leading, bottom, trailing): the layout's (`WindowLayout.pageInsets`), or none while
    /// a page fills the window.
    public static func pageInsets(layout: WindowLayout, showsToolbar: Bool, pageFullscreen: Bool)
        -> (top: Double, leading: Double, bottom: Double, trailing: Double)
    {
        pageFullscreen ? (0, 0, 0, 0) : layout.pageInsets(showsToolbar: showsToolbar)
    }
}
