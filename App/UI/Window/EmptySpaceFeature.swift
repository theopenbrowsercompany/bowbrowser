import AppKit
import BowCore

/// The empty state of a Space with no tabs: closing the Space's last tab, or switching to a Space that has none,
/// keeps the window open and fills the page area with a short line and a New Tab button, never another Space's page.
/// An active tab with no page loaded (a lone pinned tab the person closed) shows a line and a Load Tab button instead
/// of a blank page area.
@MainActor
final class EmptySpaceFeature: NSResponder, BrowserWindowFeature {
    /// The empty state, over the page area; hidden while the page area shows a page.
    let emptyView: EmptySpaceView
    private weak var window: BrowserWindowController?

    init(window: BrowserWindowController) {
        self.window = window
        emptyView = EmptySpaceView()
        emptyView.isHidden = true
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        window.pageArea.addSubview(emptyView, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: window.pageArea.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: window.pageArea.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: window.pageArea.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: window.pageArea.bottomAnchor),
        ])
        super.init()
        emptyView.newTabButton.target = window
        emptyView.newTabButton.action = #selector(BrowserWindowController.newTab(_:))
        emptyView.loadTabButton.target = self
        emptyView.loadTabButton.action = #selector(loadActiveTab(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shown while the page area shows no page, the window follows every store change with this: the empty Space
    /// state when the Space on screen has no tabs, else the unloaded tab state. Hidden while the window closes, since
    /// it loads nothing then.
    func selectedTabChanged(_ tab: (any EngineTab)?) {
        guard let window, let space = window.store.graph.activeSpaceID, tab == nil, !window.isClosing else {
            emptyView.isHidden = true
            return
        }
        emptyView.isHidden = false
        // An active tab without a page (a pinned tab or Favorite the person closed) offers to load it.
        emptyView.showsUnloadedTab = window.tabList.activeID != nil || !window.store.graph.tabIDs(in: space).isEmpty
    }

    /// Loads the active tab the unloaded state stands for, as choosing its row does.
    @objc private func loadActiveTab(_ sender: Any?) {
        guard let window, let id = window.tabList.activeID else { return }
        window.select(id)
    }
}

/// A plain Page colored view: the Bow mark, then "No tabs in this Space" and a New Tab button, or, for an active tab
/// with no page loaded, "This tab is not loaded" and a Load Tab button.
@MainActor
final class EmptySpaceView: NSView {
    /// The Bow mark, from the brand kit, at 64 points.
    let markView = NSImageView()
    static let markSize: CGFloat = 64
    static let pillHeight: CGFloat = 32
    static let pillWidth: CGFloat = 112
    let messageLabel = NSTextField(labelWithString: "No tabs in this Space")
    let newTabButton = NSButton(title: "New Tab", target: nil, action: nil)
    let loadTabButton = NSButton(title: "Load Tab", target: nil, action: nil)

    /// Whether the view stands for an unloaded tab rather than an empty Space.
    var showsUnloadedTab = false {
        didSet {
            messageLabel.stringValue = showsUnloadedTab ? "This tab is not loaded" : "No tabs in this Space"
            newTabButton.isHidden = showsUnloadedTab
            loadTabButton.isHidden = !showsUnloadedTab
        }
    }

    init() {
        super.init(frame: .zero)
        // It fills the page card, which is White in both appearances, so it always draws light.
        appearance = NSAppearance(named: .aqua)
        loadTabButton.isHidden = true
        wantsLayer = true
        layer?.backgroundColor = BowBrand.page.cgColor
        // Filled pill buttons: Jam Deep with white text.
        for button in [newTabButton, loadTabButton] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = BowBrand.button.cgColor
            button.layer?.cornerRadius = Self.pillHeight / 2
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(equalToConstant: Self.pillHeight),
                button.widthAnchor.constraint(equalToConstant: Self.pillWidth),
            ])
        }
        markView.image = NSImage(named: "BowMark")
        markView.imageScaling = .scaleProportionallyUpOrDown
        markView.setAccessibilityLabel("Bow")
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = BowBrand.soft
        let stack = NSStackView(views: [markView, messageLabel, newTabButton, loadTabButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(16, after: markView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            markView.widthAnchor.constraint(equalToConstant: Self.markSize),
            markView.heightAnchor.constraint(equalToConstant: Self.markSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

}
