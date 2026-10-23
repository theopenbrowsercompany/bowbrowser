import AppKit

/// A browser window: its tabs, and one host view that shows the selected tab.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    /// Shows the selected tab. Switching tabs attaches another tab here; pages are never reloaded by a switch.
    let webView: BowWebView
    /// The window's open tabs, in order.
    private(set) var tabs: [BowTab] = []
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?

    private let profile: BowProfile

    var selectedTab: BowTab? { webView.attachedTab }

    /// Opens `url` in a new centered window, or in `window` when given (e2e runs pass an off-screen one),
    /// which is not cascaded: the caller places it.
    init(url: URL, profile: BowProfile = BowEngine.shared.defaultProfile, window givenWindow: BrowserWindow? = nil) {
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
    func openTab(url: URL, select: Bool = true) -> BowTab {
        let tab = profile.createTab(url: url)
        tabs.append(tab)
        tab.uiDelegate = self
        if select || selectedTab == nil { self.select(tab) }
        return tab
    }

    /// Shows `tab`, one of this window's tabs.
    func select(_ tab: BowTab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        webView.attach(tab)
        updateTitle()
    }

    /// A tab closes from this window, from quitting or from its page; the window follows its last tab.
    private func tabClosed(_ tab: BowTab) {
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
            tab.close { _ in }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

extension BrowserWindowController: BowTabUIDelegate {
    func tab(_ tab: BowTab, didChangeState state: BowTabState) {
        if tab === selectedTab { updateTitle() }
    }

    func tabDidClose(_ tab: BowTab) {
        tabClosed(tab)
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
