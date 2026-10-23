import AppKit
import BowCore

/// The certificate error page: when a tab's top level page fails its certificate check, the load is cancelled (the
/// engine's own error page loads under it) and the page area shows "This connection is not secure" over it while that
/// tab is shown, naming the host and what is wrong in plain words, with Go back as its primary and only action, the
/// default as Chrome's "Back to safety" is. Go back goes back in the tab's history, or closes the tab when it has no page to go back to, so the window
/// shows what it shows after Cmd+W (the start screen when the Space has no other tab). Nothing offers to go on to the
/// site: `CertificateErrorPages` holds the rules, and a way past waits until the engine can say whether the site
/// requires HTTPS. The page goes when the tab starts another navigation, crashes or closes; a tab that failed in the
/// background shows it once it is shown.
@MainActor
final class CertificateErrorFeature: NSResponder, BrowserWindowFeature {
    /// The page over the page area; hidden while the shown tab has no certificate error.
    let errorView = CertificateErrorView()
    private unowned let window: BrowserWindowController
    private var pages = CertificateErrorPages<TabID>()

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        errorView.isHidden = true
        errorView.translatesAutoresizingMaskIntoConstraints = false
        window.pageArea.addSubview(errorView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            errorView.leadingAnchor.constraint(equalTo: window.pageArea.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: window.pageArea.trailingAnchor),
            errorView.topAnchor.constraint(equalTo: window.pageArea.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: window.pageArea.bottomAnchor),
        ])
        errorView.goBackButton.target = self
        errorView.goBackButton.action = #selector(pressGoBack(_:))
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

    @objc private func pressGoBack(_ sender: Any?) {
        guard let tab = window.selectedTab else { return }
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

    private func update() {
        let page = window.isClosing ? nil : window.selectedTab.flatMap { pages.page(for: $0.tabID) }
        errorView.show(page)
    }
}

/// The certificate error page over the page card: the title, the explanation, the engine's error name and a Go back
/// pill, styled as the crashed tab page (Page fill, Text and Soft, the Jam Deep pill with white text).
@MainActor
final class CertificateErrorView: NSView {
    static let pillHeight: CGFloat = 32
    static let pillWidth: CGFloat = 112
    static let textWidth: CGFloat = 460
    let titleLabel = NSTextField(labelWithString: CertificateErrorPage.title)
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let goBackButton = NSButton(title: CertificateErrorPage.goBackTitle, target: nil, action: nil)

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

    /// Shows `page`, or hides the view for nil. Go back is the page's primary and only action; it takes no Return key
    /// equivalent, since the window would then claim Return from the toolbar and every other field while the page shows.
    func show(_ page: CertificateErrorPage?) {
        if let page {
            messageLabel.stringValue = page.message
            detailLabel.stringValue = page.errorName
        }
        isHidden = page == nil
    }
}
