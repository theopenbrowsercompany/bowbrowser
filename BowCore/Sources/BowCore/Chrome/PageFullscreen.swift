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
    /// The macOS full screen transition in progress: true while the window animates into full screen, false while it
    /// animates out, nil when none is. macOS ignores a toggle sent during one, so page fullscreen waits for its end.
    public private(set) var transition: Bool?
    /// The full screen state page fullscreen asked for during the transition, which the window is toggled into once
    /// the transition ends if it is not there; nil when nothing is waiting.
    public private(set) var queuedFullScreen: Bool?

    public init() {}

    /// True while a page fills the window.
    public var isActive: Bool { tab != nil }

    /// `tab`'s page entered fullscreen. Only the shown tab's page takes the window: a page in a tab that is not shown
    /// is asked to leave at once. A second request from the page already filling the window changes nothing.
    /// `windowIsFullScreen` is the window's state now; during a transition the state it is heading for counts.
    public mutating func pageEntered(_ tab: TabID, isShown: Bool, windowIsFullScreen: Bool) -> [Action] {
        guard isShown else { return [.exitPage(tab)] }
        if self.tab == tab { return [] }
        if let other = self.tab {
            // Another page held the window (it cannot be shown any more): it leaves, the window stays as it is.
            self.tab = tab
            return [.exitPage(other)]
        }
        self.tab = tab
        enteredWindowFullScreen = !(queuedFullScreen ?? transition ?? windowIsFullScreen)
        return enteredWindowFullScreen ? [.hideChrome] + setWindowFullScreen(true) : [.hideChrome]
    }

    // MARK: The window's macOS full screen transitions

    /// The window began animating into macOS full screen (`NSWindow.willEnterFullScreenNotification`), whoever asked.
    public mutating func windowWillEnterFullScreen() {
        transition = true
    }

    /// The window began animating out of macOS full screen (`NSWindow.willExitFullScreenNotification`).
    public mutating func windowWillExitFullScreen() {
        transition = false
    }

    /// The window is in macOS full screen (`NSWindow.didEnterFullScreenNotification`): a page that left while it
    /// animated takes it back out now, with one toggle.
    public mutating func windowEnteredFullScreen() -> [Action] {
        transitionEnded(isFullScreen: true)
    }

    /// The window stayed out of macOS full screen (`windowDidFailToEnterFullScreen`). A page filling the window keeps
    /// it, but leaving it no longer toggles the window, which never got there.
    public mutating func windowFailedToEnterFullScreen() -> [Action] {
        if tab != nil { enteredWindowFullScreen = false }
        return transitionEnded(isFullScreen: false)
    }

    /// The window stayed in macOS full screen (`windowDidFailToExitFullScreen`): a page that asked again while it
    /// tried to leave is already where it wants to be. Page fullscreen does not try again.
    public mutating func windowFailedToExitFullScreen() -> [Action] {
        transitionEnded(isFullScreen: true)
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
    /// A page still filling the window leaves too; the window is already out, so it is not toggled again. A page that
    /// asked to fill the window while it animated out keeps it, and the window goes back into full screen.
    public mutating func windowExitedFullScreen() -> [Action] {
        let actions = transitionEnded(isFullScreen: false)
        guard actions.isEmpty, let current = tab else { return actions }
        tab = nil
        enteredWindowFullScreen = false
        return [.exitPage(current), .showChrome]
    }

    private mutating func restore() -> [Action] {
        let toggle = enteredWindowFullScreen
        tab = nil
        enteredWindowFullScreen = false
        return toggle ? [.showChrome] + setWindowFullScreen(false) : [.showChrome]
    }

    /// Asks for the window in or out of macOS full screen: a toggle now, or, during a transition, a wish the
    /// transition's end carries out. A wish for where the transition is heading cancels an earlier one.
    private mutating func setWindowFullScreen(_ fullScreen: Bool) -> [Action] {
        guard let heading = transition else { return [.toggleWindowFullScreen] }
        queuedFullScreen = fullScreen == heading ? nil : fullScreen
        return []
    }

    /// The transition ended with the window in full screen or not: at most one toggle, and only when page fullscreen
    /// asked for the other state meanwhile.
    private mutating func transitionEnded(isFullScreen: Bool) -> [Action] {
        let wanted = queuedFullScreen
        transition = nil
        queuedFullScreen = nil
        guard let wanted, wanted != isFullScreen else { return [] }
        return [.toggleWindowFullScreen]
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
