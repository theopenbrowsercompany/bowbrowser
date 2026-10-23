import AppKit
import BowCore

/// A browser window: its tabs, and one host view that shows the selected tab. It reaches the engine only through
/// the BowCore protocols, and is the delegate of each of its tabs.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, EngineTabDelegate {
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    /// Shows the selected tab. Switching tabs shows another tab here; pages are never reloaded by a switch.
    let webView: BowWebView
    /// The window's open tabs, in order.
    private(set) var tabs: [any EngineTab] = []
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?
    /// Called with every event of the window's tabs, after the window has handled it.
    var onTabEvent: ((any EngineTab, TabEvent) -> Void)?
    /// Asked before every main frame navigation of the window's tabs; nil allows every navigation.
    var navigationPolicy: ((any EngineTab, EngineNavigation) -> NavigationPolicy)?

    private let profile: any EngineProfile

    /// The tab `webView` shows, read back from the view so it always matches the screen (the view refuses a tab
    /// that is closing).
    var selectedTab: (any EngineTab)? { tabs.first { webView.isShowing($0) } }

    /// Opens `url` in a new centered window on `profile`, or in `window` when given (e2e runs pass an off-screen
    /// one), which is not cascaded: the caller places it.
    init(url: URL, profile: any EngineProfile, window givenWindow: BrowserWindow? = nil) {
        let window =
            givenWindow
            ?? BrowserWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: Self.styleMask,
                backing: .buffered,
                defer: false
            )
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        webView = BowWebView(frame: NSRect(origin: .zero, size: contentSize))
        self.profile = profile
        window.title = "Bow"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        if givenWindow == nil { window.center() }
        super.init(window: window)
        if givenWindow != nil {
            // A window controller cascades its window to a new spot; the caller places a given window itself.
            shouldCascadeWindows = false
        }
        window.delegate = self
        openTab(url: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Opens `url` in a new tab of this window's profile, selecting it unless `select` is false.
    @discardableResult
    func openTab(url: URL, select: Bool = true) -> any EngineTab {
        let tab = profile.createTab(url: url)
        tab.delegate = self
        tabs.append(tab)
        if select || selectedTab == nil { self.select(tab) }
        return tab
    }

    /// Shows `tab`, one of this window's tabs.
    func select(_ tab: any EngineTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        webView.show(tab)
        updateTitle()
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .stateChanged:
            if tab === selectedTab { updateTitle() }
        case .closed:
            // A tab closes from this window, from quitting or from its page; the window follows its last tab.
            tabClosed(tab)
        default:
            break
        }
        onTabEvent?(tab, event)
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        navigationPolicy?(tab, navigation) ?? .allow
    }

    private func tabClosed(_ tab: any EngineTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        if selectedTab == nil, !tabs.isEmpty {
            select(tabs[min(index, tabs.count - 1)])
        }
        if tabs.isEmpty {
            window?.close()
        } else {
            updateTitle()
        }
    }

    private func updateTitle() {
        let title = selectedTab?.state.title ?? ""
        window?.title = title.isEmpty ? "Bow" : title
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if tabs.isEmpty { return true }
        // Close every tab, each running its page's unload handlers; the window closes once the last one has.
        // A page the person chooses to stay on keeps its tab and the window open. Each close request asks the
        // pages again, as quitting again does.
        for tab in tabs {
            Task { _ = await tab.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// A window whose close requests (close button, Cmd+W, Window > Close) wait for the page to close first.
/// AppKit's `performClose(_:)` plays the alert sound whenever `windowShouldClose(_:)` says no, which here only
/// means "the page is closing, the window follows", so this asks the delegate without the sound.
class BrowserWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}
