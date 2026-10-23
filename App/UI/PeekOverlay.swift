import AppKit
import BowCore

/// The Peek's look, filling the page area over the panes (`BrowserWindowController.addPageOverlay`): the page dimmed
/// behind it, a centered card in the page card's style (white, the card radius, the one soft shadow) showing the Peek's
/// page, and a small toolbar row above the card's trailing edge with Open as Tab and Close, as Arc's Peek shows its
/// controls. A press on the dimmed page around the card closes the Peek, as in Arc. `PeekLayout` places the card.
@MainActor
final class PeekOverlayView: NSView {
    /// The host view of the Peek's page, inside the card.
    let webView: BowWebView
    /// Open as Tab: moves the page into a tab of its own, without reloading it.
    let openButton: NSButton
    /// Close: dismisses the Peek.
    let closeButton: NSButton
    /// The card: casts the shadow and holds the clipped page.
    let card = NSView()
    private let clip = NSView()
    private let toolbar = NSStackView()

    /// Called for Close and for a press on the dimmed page.
    var onDismiss: (() -> Void)?
    /// Called for Open as Tab.
    var onPromote: (() -> Void)?

    /// The dimmed page behind the card: Night, the brand's shadow color, at this opacity.
    static let backdropOpacity: CGFloat = 0.3
    /// The diameter of the toolbar's round buttons.
    static let buttonSize: CGFloat = 26

    override init(frame frameRect: NSRect) {
        webView = BowWebView(frame: NSRect(origin: .zero, size: frameRect.size))
        openButton = Self.makeButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open as Tab")
        closeButton = Self.makeButton(symbol: "xmark", label: "Close Peek")
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = BowBrand.shadow.withAlphaComponent(Self.backdropOpacity).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Peek")

        card.wantsLayer = true
        card.layer?.masksToBounds = false
        card.shadow = BowBrand.softShadow()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = BowBrand.radiusCard
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = BowBrand.page.cgColor
        clip.addSubview(webView)
        card.addSubview(clip)
        addSubview(card)

        openButton.target = self
        openButton.action = #selector(promote(_:))
        closeButton.target = self
        closeButton.action = #selector(dismiss(_:))
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.addArrangedSubview(openButton)
        toolbar.addArrangedSubview(closeButton)
        addSubview(toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func makeButton(symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.backgroundColor = BowBrand.page.cgColor
        button.layer?.cornerRadius = buttonSize / 2
        button.contentTintColor = BowBrand.soft
        button.shadow = BowBrand.softShadow()
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
        return button
    }

    override func layout() {
        super.layout()
        let frame = PeekLayout.cardFrame(width: bounds.width, height: bounds.height)
        card.frame = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        clip.frame = card.bounds
        webView.frame = clip.bounds
        card.layer?.shadowPath = CGPath(
            roundedRect: card.bounds, cornerWidth: BowBrand.radiusCard, cornerHeight: BowBrand.radiusCard,
            transform: nil)
        let size = toolbar.fittingSize
        let rowHeight = CGFloat(PeekLayout.toolbarHeight)
        toolbar.frame = NSRect(
            x: card.frame.maxX - size.width, y: card.frame.maxY + (rowHeight - size.height) / 2,
            width: size.width, height: size.height)
    }

    // MARK: Actions

    @objc private func promote(_ sender: Any?) {
        onPromote?()
    }

    @objc private func dismiss(_ sender: Any?) {
        onDismiss?()
    }

    /// A press on the dimmed page around the card (the card and the buttons take their own presses).
    override func mouseDown(with event: NSEvent) {
        pressBackdrop()
    }

    /// What a press on the dimmed page does: dismisses the Peek.
    func pressBackdrop() {
        onDismiss?()
    }

    /// Takes the presses that would otherwise reach the page underneath, so the page under the Peek is never clicked.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
