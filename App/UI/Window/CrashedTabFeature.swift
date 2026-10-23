import AppKit
import BowCore

/// The crashed tab page: when a tab's renderer ends (a crash, a kill, running out of memory), the page is gone until
/// the tab reloads, so its pane shows "This page crashed" with a Reload button over it while that tab is shown. With a
/// split view showing, each crashed pane has its own, over that pane only, focused or not, and the other panes stay
/// usable. Reload reloads that pane's tab and takes its overlay away; a navigation that starts any other way (the
/// address bar, a link in another feature) does too. A tab crashed in the background shows it once it is shown.
@MainActor
final class CrashedTabFeature: NSResponder, BrowserWindowFeature {
    /// One overlay per pane the page area can show, in pane order of the crashed panes; hidden while unused.
    let crashedViews: [CrashedTabView]
    private unowned let window: BrowserWindowController
    private var crashed: Set<TabID> = []
    /// The tab each overlay covers, nil for a hidden one.
    private var covered: [TabID?]
    /// The pane views whose frame changes move the overlays.
    private var observedPanes: [NSView] = []

    init(window: BrowserWindowController) {
        self.window = window
        crashedViews = (0..<SidebarSplit.maximumPanes).map { _ in CrashedTabView() }
        covered = Array(repeating: nil, count: crashedViews.count)
        super.init()
        for (index, view) in crashedViews.enumerated() {
            view.isHidden = true
            window.pageArea.addSubview(view, positioned: .above, relativeTo: nil)
            view.reloadButton.tag = index
            view.reloadButton.target = self
            view.reloadButton.action = #selector(reload(_:))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The overlay over the pane showing `tab`, nil while that pane shows none.
    func crashedView(covering tab: any EngineTab) -> CrashedTabView? {
        covered.firstIndex { $0 == tab.tabID }.map { crashedViews[$0] }
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) { update() }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .renderProcessGone:
            crashed.insert(tab.tabID)
        case .didStartNavigation:
            crashed.remove(tab.tabID)
        default:
            return
        }
        update()
    }

    func tabDidClose(_ tab: any EngineTab) {
        crashed.remove(tab.tabID)
        update()
    }

    /// Reload on the overlay at the button's tag: reloads the tab of the pane it covers.
    @objc private func reload(_ sender: Any?) {
        guard let index = (sender as? NSButton)?.tag, covered.indices.contains(index), let id = covered[index],
            crashed.contains(id), let tab = window.shownPanes.first(where: { $0.tab.tabID == id })?.tab
        else { return }
        crashed.remove(id)
        tab.reload()
        update()
    }

    /// Covers each shown pane whose tab crashed with an overlay, and hides the rest.
    private func update() {
        let panes = window.isClosing ? [] : window.shownPanes
        let crashedPanes = panes.filter { crashed.contains($0.tab.tabID) }
        for (index, view) in crashedViews.enumerated() {
            covered[index] = index < crashedPanes.count ? crashedPanes[index].tab.tabID : nil
            view.isHidden = covered[index] == nil
        }
        observe(panes.map(\.view))
        placeOverlays()
    }

    /// Puts each overlay over its pane.
    private func placeOverlays() {
        for (index, view) in crashedViews.enumerated() {
            guard let id = covered[index], let pane = window.shownPanes.first(where: { $0.tab.tabID == id })?.view
            else { continue }
            view.frame = pane.convert(pane.bounds, to: window.pageArea)
        }
    }

    /// Follows the frames of `panes`, which change when the window resizes or a divider moves.
    private func observe(_ panes: [NSView]) {
        guard !panes.elementsEqual(observedPanes, by: ===) else { return }
        for view in observedPanes {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view)
        }
        for view in panes {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(paneFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: view)
        }
        observedPanes = panes
    }

    @objc private func paneFrameChanged(_ notification: Notification) {
        placeOverlays()
    }
}

/// A plain Page colored view over the page card: "This page crashed" and a Reload pill, the one the unloaded tab state
/// uses (Jam Deep with white text).
@MainActor
final class CrashedTabView: NSView {
    static let message = "This page crashed"
    static let pillHeight: CGFloat = 32
    static let pillWidth: CGFloat = 112
    let messageLabel = NSTextField(labelWithString: CrashedTabView.message)
    let reloadButton = NSButton(title: "Reload", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        // It fills the page card, which is White in both appearances, so it always draws light.
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = BowBrand.page.cgColor
        messageLabel.font = BowBrand.ui(15)
        messageLabel.textColor = BowBrand.text
        reloadButton.isBordered = false
        reloadButton.wantsLayer = true
        reloadButton.layer?.backgroundColor = BowBrand.button.cgColor
        reloadButton.layer?.cornerRadius = Self.pillHeight / 2
        reloadButton.attributedTitle = NSAttributedString(
            string: reloadButton.title,
            attributes: [.font: BowBrand.ui(weight: .semibold), .foregroundColor: NSColor.white])
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [messageLabel, reloadButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            reloadButton.widthAnchor.constraint(equalToConstant: Self.pillWidth),
        ])
        setAccessibilityLabel(Self.message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
