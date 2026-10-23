import AppKit
import BowCore

/// Cmd+Shift+C (Edit > Copy Current URL): copies the shown page's address to the pasteboard, as a URL and as plain
/// text, and shows "Copied URL" over the page for about 1.5 seconds. A tab with no copyable address (a blank tab,
/// an internal page, an empty Space) copies nothing and shows nothing (`CopyableURL`).
///
/// The shortcut is claimed before the page (`KeyShortcuts`), so a page that handles the key itself never sees it;
/// the menu item reaches the same code through the responder chain and validates with the shown tab.
@MainActor
final class CopyURLFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    /// How long the confirmation stays before it fades.
    static let confirmationDuration: Duration = .milliseconds(1500)

    private unowned let window: BrowserWindowController
    /// Where the address goes: the general pasteboard, or a private one a test gives.
    var pasteboard: NSPasteboard = .general
    let confirmation = CopyConfirmationView()
    /// The pending fade; a new copy replaces it, so presses in a row show one confirmation.
    private var fadeTask: Task<Void, Never>?

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        confirmation.alphaValue = 0
        confirmation.isHidden = true
        if let content = window.window?.contentView {
            confirmation.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(confirmation)
            NSLayoutConstraint.activate([
                confirmation.centerXAnchor.constraint(equalTo: window.pageArea.centerXAnchor),
                confirmation.bottomAnchor.constraint(equalTo: window.pageArea.bottomAnchor, constant: -24),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.edit.addItem(.separator())
        // An uppercase key equivalent is Shift with that letter.
        menus.edit.addItem(withTitle: "Copy Current URL", action: #selector(copyCurrentURL(_:)), keyEquivalent: "C")
    }

    @objc func copyCurrentURL(_ sender: Any?) {
        _ = copyAddress()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyCurrentURL(_:)): copyableAddress != nil
        default: true
        }
    }

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard KeyShortcuts.shortcut(for: event, claimedBy: .toolbar) == .copyURL else { return false }
        // The key is ours even with nothing to copy, so the page never sees it.
        _ = copyAddress()
        return true
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        // The confirmation belongs to the page it was shown over, so another tab (or none) clears it.
        hideConfirmation()
    }

    private var copyableAddress: URL? {
        guard let tab = window.selectedTab, !tab.isClosed else { return nil }
        return CopyableURL.address(for: tab.state.url)
    }

    /// Copies the shown page's address and confirms; false when there is none.
    @discardableResult
    private func copyAddress() -> Bool {
        guard let url = copyableAddress, !window.isClosing else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
        showConfirmation()
        return true
    }

    private func showConfirmation() {
        fadeTask?.cancel()
        confirmation.layer?.removeAllAnimations()
        confirmation.isHidden = false
        confirmation.alphaValue = 1
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationDuration)
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.25
            self.confirmation.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
            // A newer copy cancels this task, so it only hides what has faded.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.confirmation.isHidden = true
        }
    }

    private func hideConfirmation() {
        fadeTask?.cancel()
        fadeTask = nil
        confirmation.layer?.removeAllAnimations()
        confirmation.alphaValue = 0
        confirmation.isHidden = true
    }
}

/// The small rounded label that confirms a copy: the active fill, the lift shadow and Text color.
@MainActor
final class CopyConfirmationView: NSView {
    static let message = "Copied URL"
    private let label = NSTextField(labelWithString: CopyConfirmationView.message)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = BowBrand.softShadow()
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = BowBrand.text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityLabel(Self.message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Never takes a click: the page under it keeps them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = BowBrand.active.cgColor
        }
        layer?.cornerRadius = BowBrand.radiusCard
        layer?.cornerCurve = .continuous
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: BowBrand.radiusCard, cornerHeight: BowBrand.radiusCard, transform: nil)
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}
