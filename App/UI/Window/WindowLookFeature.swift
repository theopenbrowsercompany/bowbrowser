import AppKit
import BowCore

/// The window's look: one Frame colored surface from the top edge down (full size content under a transparent title
/// bar with no toolbar, so the sidebar runs to the top and the window buttons sit in it), the back, forward and
/// reload buttons in the sidebar's top row, and the page as a card inset from the frame, its corners rounded and a
/// soft shadow under it, all through the window core's page container seam.
@MainActor
final class WindowLookFeature: NSResponder, BrowserWindowFeature {
    init(window: BrowserWindowController) {
        super.init()
        window.usesFullSizeContent = true
        window.pageCornerRadius = BowBrand.radiusCard
        // The leading edge meets the sidebar, whose own padding spaces it.
        let inset = BowBrand.pageInset
        window.pageInsets = NSEdgeInsets(top: inset, left: 0, bottom: inset, right: inset)
        window.window?.backgroundColor = BowBrand.frame
        let soft = BowBrand.softShadow()
        window.pageShadow = PageShadow(
            color: soft.shadowColor ?? .clear, radius: soft.shadowBlurRadius, offset: soft.shadowOffset,
            fill: BowBrand.page)
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
