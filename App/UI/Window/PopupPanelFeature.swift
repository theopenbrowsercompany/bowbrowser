import AppKit
import BowCore

/// Shows the pages `PopupPolicy` answers `.popupPanel` (a sized `window.open` from a click, an identity provider's
/// sign in page) in a popup panel: a small window attached to the browser window as a child window, centered over it
/// and sized from `window.open`'s features (`PopupPanelLayout`), as Arc shows login popups in a small window of their
/// own instead of a tab. The page arrives through the popup tab path, so it keeps `window.opener` and its messages
/// reach the page that opened it.
///
/// A panel closes when its page closes (the page calls `window.close()`, the person closes the panel, quitting), when
/// the tab that opened it closes, and when its window closes, so a panel never outlives its opener's window. Pages the
/// panel's page opens go to the engine's own popup window, as the pages of popup windows do.
@MainActor
final class PopupPanelFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?
    /// The open panels, oldest first.
    private(set) var panels: [PopupPanel] = []
    /// The browser window whose close the feature watches, once a panel has opened.
    private weak var observedWindow: NSWindow?

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func didOpenPopup(_ newTab: any EngineTab, from tab: any EngineTab, request: PopupRequest) -> Bool {
        guard PopupPolicy.opensPanel(request), let controller = window, let parent = controller.window,
            !newTab.isClosed
        else { return false }
        if observedWindow !== parent {
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.willCloseNotification, object: observedWindow)
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(parentWillClose(_:)), name: NSWindow.willCloseNotification, object: parent)
            observedWindow = parent
        }
        let panel = PopupPanel(
            tab: newTab, opener: tab, request: request, parent: parent, cascade: panels.count,
            navigationPolicy: controller.navigationPolicy
        ) { [weak self] closed in
            self?.panels.removeAll { $0 === closed }
        }
        panels.append(panel)
        return true
    }

    func tabDidClose(_ tab: any EngineTab) {
        // A sign in panel reports to the page that opened it; without that page it has nothing left to do.
        for panel in panels where panel.opener === tab { panel.close(force: true) }
    }

    @objc private func parentWillClose(_ notification: Notification) {
        for panel in panels { panel.close(force: true) }
    }
}

/// One popup panel: its child window, the web view showing the page, and the page's delegate.
@MainActor
final class PopupPanel: NSObject, NSWindowDelegate, EngineTabDelegate {
    let tab: any EngineTab
    /// The tab whose page opened this one. Weak: the window owns it.
    private(set) weak var opener: (any EngineTab)?
    let window: PopupPanelWindow
    private let webView: BowWebView
    /// The panel page's alert, confirm and prompt, as sheets on the panel under the same rules as a tab's. The panel
    /// always shows its page, so a dialog comes up at once.
    let dialogs: PageDialogSheets
    /// The panel page's sign in requests (an identity provider behind HTTP sign in), as a sheet on the panel under the
    /// same rules as a tab's, through the same presenter as its dialogs, so one waits for the other.
    let signIn: SignInSheets
    private let navigationPolicy: ((any EngineTab, EngineNavigation) -> NavigationPolicy)?
    private var onClosed: ((PopupPanel) -> Void)?

    init(
        tab: any EngineTab,
        opener: any EngineTab,
        request: PopupRequest,
        parent: NSWindow,
        cascade: Int,
        navigationPolicy: ((any EngineTab, EngineNavigation) -> NavigationPolicy)?,
        onClosed: @escaping (PopupPanel) -> Void
    ) {
        self.tab = tab
        self.opener = opener
        self.navigationPolicy = navigationPolicy
        self.onClosed = onClosed
        let available = parent.contentRect(forFrameRect: parent.frame).size
        let contentSize = PopupPanelLayout.contentSize(for: request, within: available)
        window = PopupPanelWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        webView = BowWebView(frame: NSRect(origin: .zero, size: contentSize))
        dialogs = PageDialogSheets(window: window, shownTab: tab.tabID)
        signIn = SignInSheets(window: window, shownTab: tab.tabID)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = request.targetURL?.host ?? ""
        window.subtitle = ""
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.contentMinSize = PopupPanelLayout.minimumSize
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        var frame = PopupPanelLayout.frame(size: window.frame.size, centeredIn: parent.frame)
        // Each further panel sits a little lower and to the right, starting over every few so none leaves its window.
        let step = PopupPanelLayout.margin * CGFloat(cascade % 4)
        frame = frame.offsetBy(dx: step, dy: -step)
        window.setFrame(frame, display: false)
        tab.delegate = self
        window.attach(to: parent)
        webView.show(tab)
        if parent.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            webView.focusAttachedTab()
        }
    }

    /// Closes the page, running its beforeunload handler once (a close already under way is not asked again); the
    /// panel goes once the page has closed. With `force` (its opener tab or window has gone) the panel leaves the
    /// screen at once, and a page that stays is unloaded, never kept unseen.
    func close(force: Bool = false) {
        guard !tab.isClosed else { return finish() }
        if force {
            forced = true
            removeWindow()
        }
        guard !isClosing else { return }
        isClosing = true
        let tab = tab
        Task { [weak self] in
            let closed = await tab.close()
            guard !closed else { return }
            self?.isClosing = false
            if self?.forced ?? true { _ = await tab.unload() }
        }
    }

    /// True while a close of the page is under way.
    private var isClosing = false
    /// True once the panel must go whatever the page answers.
    private var forced = false

    /// Takes the panel off the screen and lets go of it, once its page has closed (or will not be shown again).
    private func finish() {
        removeWindow()
        onClosed?(self)
        onClosed = nil
    }

    private func removeWindow() {
        // A dialog or sign in up as a sheet is answered as cancelled and taken down first: AppKit refuses to close a
        // window that has a sheet.
        dialogs.close()
        signIn.close()
        guard window.isVisible || window.parent != nil else { return }
        webView.detach()
        window.parent?.removeChildWindow(window)
        window.delegate = nil
        window.close()
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The close button and Close Window ask the page first; the panel follows once it has closed.
        close()
        return false
    }

    /// Close Tab (Cmd+W) in the panel closes the panel, as it would close a tab.
    @objc func closeActiveTab(_ sender: Any?) {
        close()
    }

    // MARK: EngineTabDelegate

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .stateChanged(let state):
            let host = state.url?.host ?? ""
            window.title = state.title.isEmpty ? host : state.title
            window.subtitle = state.title.isEmpty ? "" : host
        case .didStartNavigation, .renderProcessGone:
            dialogs.navigated(tab.tabID)
            signIn.navigated(tab.tabID)
        case .closed, .unloaded:
            finish()
        default:
            break
        }
    }

    func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer {
        await dialogs.run(dialog, for: tab.tabID)
    }

    func tab(_ tab: any EngineTab, answer challenge: AuthChallenge) async -> AuthCredentials? {
        await signIn.answer(challenge, for: tab.tabID)
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        navigationPolicy?(tab, navigation) ?? .allow
    }
}

/// The popup panel's window: it stays where it is put over its browser window (also an e2e window kept off every
/// screen), and its close requests wait for the page without the alert sound, as `BrowserWindow`'s do.
final class PopupPanelWindow: NSWindow {
    /// The browser window stays the main window, so menu commands the panel does not handle (New Tab, Find, the
    /// sidebar's) still reach it and its features.
    override var canBecomeMain: Bool { false }

    override var isRestorable: Bool {
        get { false }
        set {}
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Attaches the panel to `parent` where it is. `addChildWindow(_:ordered:)` moves a window it orders in for the
    /// first time onto the main screen, away from its parent (and onto the screen for an e2e window kept off every
    /// screen), so the move it makes while attaching is ignored.
    func attach(to parent: NSWindow) {
        holdsOrigin = true
        parent.addChildWindow(self, ordered: .above)
        holdsOrigin = false
    }

    private var holdsOrigin = false

    override func setFrameOrigin(_ point: NSPoint) {
        guard !holdsOrigin else { return }
        #if BOW_E2E  // E2E seam: AppKit moves a panel with setFrameOrigin(_:) to attach a sheet to it.
            if let keep = Self.e2eKeepFrame {
                return super.setFrameOrigin(keep(NSRect(origin: point, size: frame.size), self).origin)
            }
        #endif
        super.setFrameOrigin(point)
    }

    #if BOW_E2E  // E2E seam: e2e runs keep panels off every screen, where AppKit moves one to show a sheet on it.
        /// Given the frame asked for and the window, the frame to take.
        static var e2eKeepFrame: ((NSRect, NSWindow) -> NSRect)?

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            super.setFrame(Self.e2eKeepFrame?(frameRect, self) ?? frameRect, display: flag)
        }

        override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
            super.setFrame(
                Self.e2eKeepFrame?(frameRect, self) ?? frameRect, display: displayFlag, animate: animateFlag)
        }
    #endif

    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}
