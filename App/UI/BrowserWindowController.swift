import AppKit
import BowCore

/// A browser window: its tabs, and one host view that shows the selected tab. It reaches the engine only through
/// the BowCore protocols, and is the delegate of each of its tabs.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, EngineTabDelegate {
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    /// Shows the selected tab. Switching tabs shows another tab here; pages are never reloaded by a switch.
    let webView: BowWebView
    /// The find in page bar, floating over the page's top right corner while shown (Cmd+F).
    let findBar = FindBar()
    /// The tab the find bar searches in while it is shown; the bar closes when another tab is shown.
    private var findTab: (any EngineTab)?
    /// The window's open tabs, in order.
    private(set) var tabs: [any EngineTab] = []
    /// Called when the window has closed, so the owner can let go of this controller.
    var onClose: ((BrowserWindowController) -> Void)?
    /// Called with every event of the window's tabs, after the window has handled it.
    var onTabEvent: ((any EngineTab, TabEvent) -> Void)?
    /// Asked before every main frame navigation of the window's tabs; nil allows every navigation.
    var navigationPolicy: ((any EngineTab, EngineNavigation) -> NavigationPolicy)?

    private let profile: any EngineProfile
    /// The back, forward and reload or stop buttons in the window's toolbar.
    let navigationToolbar = NavigationToolbar()
    /// What the navigation controls offer for the selected tab; the toolbar and the menu items follow it.
    private(set) var navigationControls = NavigationControls.disabled

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
        window.contentView = Self.contentView(webView: webView, findBar: findBar)
        if givenWindow == nil { window.center() }
        super.init(window: window)
        if givenWindow != nil {
            // A window controller cascades its window to a new spot; the caller places a given window itself.
            shouldCascadeWindows = false
        }
        window.delegate = self
        navigationToolbar.install(in: window, target: self)
        findBar.onTextChange = { [weak self] _ in self?.runFind(forward: true) }
        findBar.onStep = { [weak self] forward in self?.runFind(forward: forward) }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
        openTab(url: url)
    }

    /// The window's content: the web view filling it, with the hidden find bar over its top right corner.
    private static func contentView(webView: BowWebView, findBar: FindBar) -> NSView {
        let content = NSView(frame: webView.frame)
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        ])
        return content
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
        if let findTab, findTab !== tab { closeFindBar() }
        webView.show(tab)
        updateTitle()
        updateNavigationControls()
    }

    /// Closes `tab`, one of this window's tabs, after its page's beforeunload handler runs. Returns true once it has
    /// closed, and false when the person chose to stay at the page's leave prompt, which keeps the tab and its
    /// page as they were. The window shows a neighbor when the shown tab closes, and closes with its last tab.
    /// A tab that is not in this window (another window's, or one already closed) is left alone, and the result
    /// is whether it is closed.
    @discardableResult
    func closeTab(_ tab: any EngineTab) async -> Bool {
        guard tabs.contains(where: { $0 === tab }) else { return tab.isClosed }
        return await tab.close()
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .stateChanged:
            if tab === selectedTab {
                updateTitle()
                updateNavigationControls()
            }
        case .findResult(let result):
            if tab === findTab { findBar.show(result) }
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

    // MARK: Find in page

    /// Edit > Find (Cmd+F): shows the find bar over the shown tab with the keyboard in its field, searching again
    /// for the text it kept from last time.
    @objc func showFindBar(_ sender: Any?) {
        guard let tab = selectedTab else { return }
        let wasShown = !findBar.isHidden
        findTab = tab
        findBar.isHidden = false
        findBar.focus()
        if !wasShown { runFind(forward: true) }
    }

    /// Edit > Find Next (Cmd+G), also Enter in the find bar.
    @objc func findNext(_ sender: Any?) {
        stepFind(forward: true)
    }

    /// Edit > Find Previous (Shift+Cmd+G), also Shift+Enter in the find bar.
    @objc func findPrevious(_ sender: Any?) {
        stepFind(forward: false)
    }

    private func stepFind(forward: Bool) {
        // A closed bar opens and searches again, which already makes a match active; stepping too would skip one.
        if findBar.isHidden {
            showFindBar(nil)
        } else {
            runFind(forward: forward)
        }
    }

    /// Searches the find bar's tab for the bar's text: a new search when the text changed, otherwise a step to the
    /// next or previous match. Empty text stops the search and clears the count.
    private func runFind(forward: Bool) {
        guard let findTab else { return }
        let text = findBar.text
        if text.isEmpty {
            findTab.stopFind()
            findBar.show(nil)
        } else {
            findTab.find(text, forward: forward, matchCase: false)
        }
    }

    /// Hides the find bar and stops its search, clearing the page's highlights. The bar keeps its text for next
    /// time, and the keyboard goes back to the page.
    func closeFindBar() {
        guard let tab = findTab else { return }
        findTab = nil
        tab.stopFind()
        findBar.show(nil)
        let hadKeyboard = findBar.field.currentEditor() != nil
        findBar.isHidden = true
        // Chromium's view, which BowWebView holds while it shows a tab, takes the keyboard.
        if hadKeyboard { window?.makeFirstResponder(webView.subviews.first) }
    }

    private func tabClosed(_ tab: any EngineTab) {
        if tab === findTab { closeFindBar() }
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
        updateNavigationControls()
    }

    // MARK: Navigation controls

    /// Goes back in the selected tab's history (toolbar button, History > Back, Cmd+[).
    @objc func goBack(_ sender: Any?) {
        selectedTab?.goBack()
    }

    /// Goes forward in the selected tab's history (toolbar button, History > Forward, Cmd+]).
    @objc func goForward(_ sender: Any?) {
        selectedTab?.goForward()
    }

    /// Reloads the selected tab (toolbar button while idle, View > Reload Page, Cmd+R), also while it loads.
    @objc func reloadPage(_ sender: Any?) {
        selectedTab?.reload()
    }

    /// Stops the selected tab's load (toolbar button while loading, View > Stop, Cmd+.).
    @objc func stopLoading(_ sender: Any?) {
        selectedTab?.stop()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)): navigationControls.canGoBack
        case #selector(goForward(_:)): navigationControls.canGoForward
        case #selector(reloadPage(_:)): navigationControls.canReload
        case #selector(stopLoading(_:)): navigationControls.canStop
        default: true
        }
    }

    /// Applies the selected tab's last pushed state to its tab model, reads the controls from that model and shows
    /// them in the toolbar.
    private func updateNavigationControls() {
        // The window does not keep a TabList yet, so the model tab is made here from the engine's snapshot; once the
        // window's tabs live in a TabList, its active tab is read instead.
        let activeTab: BrowserTab? = selectedTab.flatMap { tab in
            guard !tab.isClosed else { return nil }
            var model = BrowserTab()
            model.apply(tab.state)
            return model
        }
        navigationControls = NavigationControls(activeTab: activeTab)
        navigationToolbar.show(navigationControls)
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
