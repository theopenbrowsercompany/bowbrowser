import AppKit
import BowCore

/// The certificate error page: when a tab's top level page fails its certificate check, the load is cancelled (the
/// engine's own error page loads under it) and the tab's pane shows "This connection is not secure" over it while that
/// tab is shown, naming the host and what is wrong in plain words, with Go back as its primary and only action, the
/// default as Chrome's "Back to safety" is. Go back goes back in the tab's history, or closes the tab when it has no page to go back to, so the window
/// shows what it shows after Cmd+W (the start screen when the Space has no other tab). Nothing offers to go on to the
/// site: `CertificateErrorPages` holds the rules, and a way past waits until the engine can say whether the site
/// requires HTTPS. The page goes when the tab starts another navigation, crashes or closes; a tab that failed in the
/// background shows it once it is shown.
///
/// In split view the page covers only the pane whose tab failed, so the other panes stay usable. Over the focused pane
/// it takes the keyboard as it comes up (`CertificateErrorPage.takesKeyboard`), so Return presses Go back, and gives it
/// back to the page when it goes. While the shown tab shows it, the URL field shows the address that failed, marked not
/// secure (`CertificateErrorPage.addressLine`), never the address of the page before.
@MainActor
final class CertificateErrorFeature: NSResponder, BrowserWindowFeature {
    /// One page view per pane, leading to trailing, made as panes appear; each sits over its pane and is hidden while
    /// its pane's tab has no certificate error. The first is made with the window, so later page overlays (Peek's card)
    /// stay above every one of them.
    private(set) var errorViews: [CertificateErrorView] = []
    /// The tab each page view covers, by view.
    private var coveredTabs: [TabID?] = []
    private unowned let window: BrowserWindowController
    private var pages = CertificateErrorPages<TabID>()
    /// The pane views whose frame changes move the pages over them.
    private var observedPanes: Set<ObjectIdentifier> = []

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        addErrorView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The page `tab` shows, or nil.
    func page(for tab: any EngineTab) -> CertificateErrorPage? {
        pages.page(for: tab.tabID)
    }

    /// Whether no tab is tracked, as after every tab closed.
    var isIdle: Bool { pages.isEmpty }

    func decideCertificateError(_ error: CertificateError, for tab: any EngineTab) async -> CertificateErrorDecision? {
        // Never a silent way on: the load is cancelled, and the tab shows the page if the error is still its own.
        if pages.certificateFailed(tab.tabID, error) { update() }
        return .cancel
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) { update() }

    func paneDividerMoved(fractions: [Double]) { placeViews() }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .didStartNavigation(let navigation):
            pages.navigationStarted(tab.tabID, to: navigation.url)
        case .didRedirect(let navigation):
            pages.redirected(tab.tabID, to: navigation.url)
        case .renderProcessGone:
            // The crashed tab page takes over.
            pages.forget(tab.tabID)
        case .stateChanged(let state):
            // A Go back pressed before the failed load settled runs once it has.
            if !state.isLoading, goBackPending.contains(tab.tabID) { goBack(tab) }
            return
        default:
            return
        }
        goBackPending.remove(tab.tabID)
        update()
    }

    func tabDidClose(_ tab: any EngineTab) {
        goBackPending.remove(tab.tabID)
        pages.forget(tab.tabID)
        update()
    }

    /// Tabs whose Go back waits for their failed load to settle.
    private var goBackPending: Set<TabID> = []

    /// Go back on a page view, pressed or by Return: goes back in the tab that view covers.
    @objc private func pressGoBack(_ sender: Any?) {
        guard let button = sender as? NSView,
            let index = errorViews.firstIndex(where: { button.isDescendant(of: $0) }),
            let id = coveredTabs[index], let tab = window.tabs.first(where: { $0.tabID == id })
        else { return }
        goBack(tab)
    }

    private func goBack(_ tab: any EngineTab) {
        goBackPending.remove(tab.tabID)
        guard pages.page(for: tab.tabID) != nil else { return }
        switch CertificateErrorPage.goBack(canGoBack: tab.state.canGoBack, isLoading: tab.state.isLoading) {
        case .history:
            tab.goBack()
        case .closeTab:
            Task { await window.closeTab(tab) }
        case .waitForLoad:
            goBackPending.insert(tab.tabID)
        }
    }

    // MARK: Showing

    /// Adds a page view for one more pane: just above the page views before it, so it stays under any page overlay
    /// placed since (the first goes on top of the page area as the window opens).
    private func addErrorView() {
        let view = CertificateErrorView()
        view.isHidden = true
        window.pageArea.addSubview(view, positioned: .above, relativeTo: errorViews.last)
        view.goBackButton.target = self
        view.goBackButton.action = #selector(pressGoBack(_:))
        errorViews.append(view)
        coveredTabs.append(nil)
    }

    /// Brings every pane's page view up to date with the tab its pane shows, then the keyboard and the URL field.
    private func update() {
        let panes = window.isClosing ? [] : window.paneViews
        let tabs = window.tabs
        let focusedPane = panes.isEmpty ? nil : window.focusedPane
        while errorViews.count < panes.count { addErrorView() }
        for (index, view) in errorViews.enumerated() {
            let pane = panes.indices.contains(index) ? panes[index] : nil
            let tab = pane.flatMap { pane in tabs.first { pane.isShowing($0) } }
            let page = tab.flatMap { pages.page(for: $0.tabID) }
            coveredTabs[index] = page == nil ? nil : tab?.tabID
            guard let pane, page != nil else {
                hide(view, pane: pane, focused: pane != nil && pane === focusedPane)
                continue
            }
            view.show(page)
            observeFrame(of: pane)
            place(view, over: pane)
            view.outlined = panes.count > 1 && pane === focusedPane
            if pane === focusedPane { takeKeyboard(view, over: pane) }
        }
        let shown = window.selectedTab.flatMap { pages.page(for: $0.tabID) }
        let line = shown?.addressLine
        window.feature(SidebarFeature.self)?.sidebar.accessory(URLField.self)?.field.certificateLine = line
        window.feature(TopTabsLayoutFeature.self)?.urlField.certificateLine = line
    }

    /// Hides `view`; when it held the keyboard, the page of its pane gets it back (when that pane has focus).
    private func hide(_ view: CertificateErrorView, pane: BowWebView?, focused: Bool) {
        let hadKeyboard = !view.isHidden && view.window?.firstResponder === view
        view.show(nil)
        guard hadKeyboard, let nsWindow = window.window else { return }
        if let pane, focused {
            pane.focusAttachedTab()
        }
        if nsWindow.firstResponder === view { nsWindow.makeFirstResponder(nil) }
    }

    /// Gives `view`, coming up over the focused `pane`, the keyboard when it is in the page it covers or nowhere.
    private func takeKeyboard(_ view: CertificateErrorView, over pane: BowWebView) {
        guard let nsWindow = window.window, nsWindow.firstResponder !== view else { return }
        let holder: CertificateErrorPage.KeyboardHolder
        switch nsWindow.firstResponder {
        case nil, is NSWindow:
            holder = .nothing
        case let responder as NSView where responder.isDescendant(of: pane):
            holder = .coveredPage
        case is NSText, is NSTextField:
            holder = .textField
        default:
            holder = .elsewhere
        }
        if CertificateErrorPage.takesKeyboard(from: holder, inFocusedPane: true) { nsWindow.makeFirstResponder(view) }
    }

    /// Places each shown page view over its pane again.
    private func placeViews() {
        for (index, pane) in window.paneViews.enumerated() where index < errorViews.count {
            if !errorViews[index].isHidden { place(errorViews[index], over: pane) }
        }
    }

    private func place(_ view: CertificateErrorView, over pane: BowWebView) {
        let frame = pane.convert(pane.bounds, to: window.pageArea)
        if view.frame != frame { view.frame = frame }
    }

    /// Follows `pane`'s frame (a window resize, a divider moving, the panes changing), so its page stays over it.
    private func observeFrame(of pane: BowWebView) {
        guard observedPanes.insert(ObjectIdentifier(pane)).inserted else { return }
        pane.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(paneFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: pane)
    }

    @objc private func paneFrameChanged(_ notification: Notification) {
        placeViews()
    }
}

/// The certificate error page over a pane: the title, the explanation, the engine's error name and a Go back pill,
/// styled as the crashed tab page (Page fill, Text and Soft, the Jam Deep pill with white text). It takes the keyboard
/// so Return (or Enter) presses Go back, and over the focused pane of a split it draws the focus outline the pane
/// draws, which it covers.
@MainActor
final class CertificateErrorView: NSView {
    static let pillHeight: CGFloat = 32
    static let pillWidth: CGFloat = 112
    static let textWidth: CGFloat = 460
    let titleLabel = NSTextField(labelWithString: CertificateErrorPage.title)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let goBackButton = NSButton(title: CertificateErrorPage.goBackTitle, target: nil, action: nil)

    /// Whether it draws the pane's focus outline.
    var outlined = false {
        didSet {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = outlined ? PaneContainer.outlineWidth : 0
        }
    }

    init() {
        super.init(frame: .zero)
        // It fills the page card, which is White in both appearances, so it always draws light.
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = BowBrand.page.cgColor
        titleLabel.font = BowBrand.ui(20, weight: .semibold)
        titleLabel.textColor = BowBrand.text
        messageLabel.font = BowBrand.ui(14)
        messageLabel.textColor = BowBrand.text
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = Self.textWidth
        detailLabel.font = BowBrand.ui(12)
        detailLabel.textColor = BowBrand.soft
        detailLabel.isSelectable = true
        goBackButton.isBordered = false
        goBackButton.wantsLayer = true
        goBackButton.layer?.backgroundColor = BowBrand.button.cgColor
        goBackButton.layer?.cornerRadius = Self.pillHeight / 2
        goBackButton.attributedTitle = NSAttributedString(
            string: goBackButton.title,
            attributes: [.font: BowBrand.ui(weight: .semibold), .foregroundColor: NSColor.white])
        goBackButton.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [titleLabel, messageLabel, detailLabel, goBackButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textWidth),
            goBackButton.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            goBackButton.widthAnchor.constraint(equalToConstant: Self.pillWidth),
        ])
        setAccessibilityLabel(CertificateErrorPage.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `page`, or hides the view for nil. Go back takes no Return key equivalent, since the window would then
    /// claim Return from the command bar and every other field while the page shows; the view takes Return itself,
    /// only while it has the keyboard.
    func show(_ page: CertificateErrorPage?) {
        if let page {
            messageLabel.stringValue = page.message
            detailLabel.stringValue = page.errorName
        }
        isHidden = page == nil
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { !isHidden }

    /// A click on the page (not on its button) gives it the keyboard, as a click into a page does.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let menuModifiers = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        guard CertificateErrorPage.pressesGoBack(characters: event.characters, commandOptionOrControl: menuModifiers)
        else {
            super.keyDown(with: event)
            return
        }
        // The same action a click on the pill sends.
        goBackButton.performClick(nil)
    }
}
