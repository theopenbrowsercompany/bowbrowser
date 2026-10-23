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
        emptyView.showsUnloadedTab = !window.store.graph.tabIDs(in: space).isEmpty
    }

    /// Loads the active tab the unloaded state stands for, as choosing its row does.
    @objc private func loadActiveTab(_ sender: Any?) {
        guard let window, let id = window.tabList.activeID else { return }
        window.select(id)
    }
}

/// A plain view: "No tabs in this Space" and a New Tab button, or, for an active tab with no page loaded, "This tab
/// is not loaded" and a Load Tab button.
@MainActor
final class EmptySpaceView: NSView {
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
        loadTabButton.isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [messageLabel, newTabButton, loadTabButton])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    /// Follows light and dark mode.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
