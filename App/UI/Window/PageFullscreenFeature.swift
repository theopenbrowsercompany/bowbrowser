import AppKit
import BowCore

/// Page fullscreen: a page that asks to fill the screen (a video's fullscreen button, `element.requestFullscreen()`)
/// gets the whole window, as in Arc and Chrome. With Alloy style the app makes the transition: the chrome (the sidebar,
/// or the top tabs bar) hides, the page card loses its inset, corners and shadow, and the window enters macOS full
/// screen unless it was there already. Escape (claimed before the page), the page's own exit, leaving macOS full
/// screen, switching tabs, closing the tab or its page going away restore the layout, and take the window out of full
/// screen only if page fullscreen put it there. `PageFullscreen` decides; this feature carries it out.
@MainActor
final class PageFullscreenFeature: NSResponder, BrowserWindowFeature {
    private unowned let window: BrowserWindowController
    private var state = PageFullscreen()
    /// The tab whose page fills the window, to ask it to leave.
    private weak var pageTab: (any EngineTab)?
    /// The window's macOS full screen, which the feature believes over the window's own style mask.
    private(set) var fullScreen: any WindowFullScreen

    init(window: BrowserWindowController) {
        self.window = window
        fullScreen = SystemWindowFullScreen(window: window.window)
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidExitFullScreen(_:)), name: NSWindow.didExitFullScreenNotification,
            object: window.window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// True while a page fills the window.
    var isActive: Bool { state.isActive }

    #if BOW_E2E  // E2E seam: the harness records the full screen toggle instead of taking over the display.
        func e2eReplaceWindowFullScreen(_ control: any WindowFullScreen) { fullScreen = control }
    #endif

    // MARK: Following the window

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .fullscreenChanged(true):
            let actions = state.pageEntered(
                tab.tabID, isShown: tab === window.selectedTab, windowIsFullScreen: fullScreen.isFullScreen)
            perform(actions, tab: tab)
            if state.tab == tab.tabID { pageTab = tab }
        case .fullscreenChanged(false):
            perform(state.pageExited(tab.tabID), tab: tab)
        case .closed, .unloaded, .renderProcessGone:
            perform(state.tabGone(tab.tabID), tab: tab)
        default:
            break
        }
    }

    func tabDidClose(_ tab: any EngineTab) {
        perform(state.tabGone(tab.tabID), tab: tab)
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        perform(state.shownTabChanged(to: tab?.tabID), tab: nil)
    }

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard KeyShortcuts.shortcut(for: event, claimedBy: .pageFullscreen) == .exitPageFullscreen,
            state.claimsEscape(in: tab.tabID)
        else { return false }
        // The page leaves fullscreen and reports it (`fullscreenChanged(false)`), which restores the layout.
        tab.exitFullscreen()
        return true
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        perform(state.windowExitedFullScreen(), tab: nil)
    }

    // MARK: Carrying it out

    private func perform(_ actions: [PageFullscreen.Action], tab: (any EngineTab)?) {
        for action in actions {
            switch action {
            case .hideChrome: setPageFills(true)
            case .showChrome: setPageFills(false)
            case .toggleWindowFullScreen:
                // A closing window goes away from full screen on its own.
                if !window.isClosing { fullScreen.toggle() }
            case .exitPage(let id):
                if let tab, tab.tabID == id {
                    tab.exitFullscreen()
                } else if let pageTab, pageTab.tabID == id {
                    pageTab.exitFullscreen()
                }
            }
        }
        if !state.isActive { pageTab = nil }
    }

    private func setPageFills(_ fills: Bool) {
        window.feature(TopTabsLayoutFeature.self)?.setPageFills(fills)
        window.feature(WindowLookFeature.self)?.setPageFills(fills)
    }
}

/// A window's macOS full screen, as page fullscreen sees it: whether the window is in it, and the toggle.
@MainActor
protocol WindowFullScreen: AnyObject {
    var isFullScreen: Bool { get }
    /// Enters or leaves full screen (`NSWindow.toggleFullScreen(_:)`); leaving posts
    /// `NSWindow.didExitFullScreenNotification` once the window is out.
    func toggle()
}

/// The real window's full screen.
@MainActor
final class SystemWindowFullScreen: WindowFullScreen {
    private weak var window: NSWindow?

    init(window: NSWindow?) {
        self.window = window
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    func toggle() {
        window?.toggleFullScreen(nil)
    }
}
