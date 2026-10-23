import AppKit

/// What the page area shows for an unloaded tab while its page loads again: the page card's white, with the tab's
/// site icon and title, and its address's host below, centred, in the brand's colors and UI face. It stands in for a
/// snapshot of the page, which the engine cannot give: the windowed page view renders blank when drawn
/// (`cacheDisplay(in:to:)`), and a hidden tab produces no frames to capture. It takes no clicks or keys.
@MainActor
final class UnloadPlaceholderView: NSView {
    static let iconSize: CGFloat = 32
    static let gap: CGFloat = 12

    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let hostLabel = NSTextField(labelWithString: "")

    init(title: String, host: String, icon: NSImage?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = BowBrand.page.cgColor
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = icon == nil
        titleLabel.stringValue = title
        titleLabel.font = BowBrand.ui(15, weight: .semibold)
        titleLabel.textColor = BowBrand.text
        hostLabel.stringValue = host
        hostLabel.font = BowBrand.ui(13)
        hostLabel.textColor = BowBrand.soft
        hostLabel.isHidden = host.isEmpty || host == title
        for label in [titleLabel, hostLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.alignment = .center
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [iconView, titleLabel, hostLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Self.gap
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateLayer() {
        // The page card is White in both appearances; resolved again here so the layer follows an appearance change.
        layer?.backgroundColor = BowBrand.page.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    // Clicks stop here, so none lands on the page under it before that page shows.
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
}
