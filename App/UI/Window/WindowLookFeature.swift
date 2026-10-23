import AppKit
import BowCore

/// The window's look: one Frame colored surface from the top edge down (full size content under a transparent title
/// bar with no toolbar, so the sidebar runs to the top and the window buttons sit in it), the back, forward and
/// reload buttons in the sidebar's top row, and the page as a card inset from the frame, its corners rounded and a
/// soft shadow under it. The card goes through the window core's page container seam except its shadow, which the
/// seam has no property for: a shadow view sits right behind the page area, pinned to its edges.
@MainActor
final class WindowLookFeature: NSResponder, BrowserWindowFeature {
    /// The page card's shadow, behind the page area in its superview.
    let shadowView = PageShadowView()

    init(window: BrowserWindowController) {
        super.init()
        window.usesFullSizeContent = true
        window.pageCornerRadius = BowBrand.radiusCard
        // The leading edge meets the sidebar, whose own padding spaces it.
        let inset = BowBrand.pageInset
        window.pageInsets = NSEdgeInsets(top: inset, left: 0, bottom: inset, right: inset)
        window.window?.backgroundColor = BowBrand.frame
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
        self.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private weak var window: BrowserWindowController?
    private var placedNavigation = false

    /// The window shows its first tab (or its empty state) once every feature exists, which is when the navigation
    /// buttons can move into the sidebar's top row.
    func selectedTabChanged(_ tab: (any EngineTab)?) {
        guard !placedNavigation, let window, let navigation = window.feature(NavigationFeature.self),
            let sidebar = window.feature(SidebarFeature.self)
        else { return }
        placedNavigation = true
        sidebar.sidebar.topRow.addArrangedSubview(navigation.toolbar.view)
    }
}

/// The page card's shadow: a Page colored rounded rect the size of the page area with the brand's soft shadow. It
/// never takes a click.
@MainActor
final class PageShadowView: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = BowBrand.radiusCard
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        layer.backgroundColor = BowBrand.page.cgColor
        shadow = BowBrand.softShadow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: BowBrand.radiusCard, cornerHeight: BowBrand.radiusCard, transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
