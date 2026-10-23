import AppKit
import BowCore

/// The crashed tab page: when a tab's renderer ends (a crash, a kill, running out of memory), the page is gone until
/// the tab reloads, so the page area shows "This page crashed" with a Reload button over it while that tab is shown.
/// Reload reloads the tab and takes the overlay away; a navigation that starts any other way (the address bar, a
/// link in another feature) does too. A tab crashed in the background shows it once it is shown.
@MainActor
final class CrashedTabFeature: NSResponder, BrowserWindowFeature {
    /// The overlay over the page area; hidden while the shown tab has a page.
    let crashedView = CrashedTabView()
    private unowned let window: BrowserWindowController
    private var crashed: Set<TabID> = []

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        crashedView.isHidden = true
        crashedView.translatesAutoresizingMaskIntoConstraints = false
        window.pageArea.addSubview(crashedView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            crashedView.leadingAnchor.constraint(equalTo: window.pageArea.leadingAnchor),
            crashedView.trailingAnchor.constraint(equalTo: window.pageArea.trailingAnchor),
            crashedView.topAnchor.constraint(equalTo: window.pageArea.topAnchor),
            crashedView.bottomAnchor.constraint(equalTo: window.pageArea.bottomAnchor),
        ])
        crashedView.reloadButton.target = self
        crashedView.reloadButton.action = #selector(reload(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

    @objc private func reload(_ sender: Any?) {
        guard let tab = window.selectedTab, crashed.contains(tab.tabID) else { return }
        crashed.remove(tab.tabID)
        tab.reload()
        update()
    }

    private func update() {
        let shows = !window.isClosing && window.selectedTab.map { crashed.contains($0.tabID) } ?? false
        crashedView.isHidden = !shows
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
