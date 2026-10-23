import AppKit
import BowCore

/// The window's look: one Frame colored surface from the top edge down (full size content under a transparent title
/// bar, so the sidebar runs to the top and the window buttons sit over it), with the page as a card inset from the
/// frame, its corners rounded and a soft shadow under it. Everything goes through the window core's page container
/// seam except the shadow, which the seam has no property for: a shadow view sits right behind the page area,
/// pinned to its edges.
@MainActor
final class WindowLookFeature: NSResponder, BrowserWindowFeature {
    /// The page card's inset from the frame on its open sides (top below the title bar, trailing, bottom); its
    /// leading edge meets the sidebar, whose own margins space it.
    static let pageInset = BowBrand.space8

    private unowned let window: BrowserWindowController
    /// The page card's shadow, behind the page area in its superview.
    let shadowView = PageShadowView()
    /// Follows the title bar's height (it changes in full screen), which sets the page card's top inset.
    private var layoutObservation: NSKeyValueObservation?

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        window.usesFullSizeContent = true
        window.pageCornerRadius = BowBrand.radiusSmall
        guard let nsWindow = window.window else { return }
        nsWindow.backgroundColor = BowBrand.frame
        let page = window.pageArea
        if let root = page.superview {
            root.addSubview(shadowView, positioned: .below, relativeTo: page)
            NSLayoutConstraint.activate([
                shadowView.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                shadowView.trailingAnchor.constraint(equalTo: page.trailingAnchor),
                shadowView.topAnchor.constraint(equalTo: page.topAnchor),
                shadowView.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            ])
        }
        layoutObservation = nsWindow.observe(\.contentLayoutRect, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updatePageInsets() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Insets the page card below the title bar (the part of the content view the content layout rect leaves out at
    /// the top) and from the trailing and bottom edges.
    private func updatePageInsets() {
        guard let nsWindow = window.window, let content = nsWindow.contentView else { return }
        let titleBar = max(0, content.frame.height - nsWindow.contentLayoutRect.maxY)
        window.pageInsets = NSEdgeInsets(
            top: titleBar, left: 0, bottom: Self.pageInset, right: Self.pageInset)
    }
}

/// The page card's shadow: a White rounded rect the size of the page area with one soft shadow (low opacity, large
/// blur, small downward offset). It never takes a click.
@MainActor
final class PageShadowView: NSView {
    static let shadowOpacity: Float = 0.12
    static let shadowRadius: CGFloat = 16
    static let shadowOffset = CGSize(width: 0, height: -2)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = BowBrand.radiusSmall
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = Self.shadowOpacity
        layer.shadowRadius = Self.shadowRadius
        layer.shadowOffset = Self.shadowOffset
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: BowBrand.radiusSmall, cornerHeight: BowBrand.radiusSmall,
            transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The card color for the view's light or dark appearance.
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = BowBrand.card.cgColor
        }
    }
}
