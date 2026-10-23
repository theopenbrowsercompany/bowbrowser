import AppKit
import BowCore

/// The empty state of a Space with no tabs: closing the Space's last tab, or switching to a Space that has none,
/// keeps the window open and fills the page area with a short line and a New Tab button, never another Space's page.
@MainActor
final class EmptySpaceFeature: NSResponder, BrowserWindowFeature {
    /// The empty state, over the page area; hidden while the Space on screen has tabs.
    let emptyView: EmptySpaceView

    init(window: BrowserWindowController) {
        emptyView = EmptySpaceView(target: window, action: #selector(BrowserWindowController.newTab(_:)))
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func storeChanged(_ graph: SidebarGraph) {
        emptyView.isHidden = graph.activeSpaceID.map { !graph.tabIDs(in: $0).isEmpty } ?? true
    }
}

/// A plain view: "No tabs in this Space" and a New Tab button.
@MainActor
final class EmptySpaceView: NSView {
    let messageLabel = NSTextField(labelWithString: "No tabs in this Space")
    let newTabButton: NSButton

    init(target: AnyObject, action: Selector) {
        newTabButton = NSButton(title: "New Tab", target: target, action: action)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [messageLabel, newTabButton])
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
