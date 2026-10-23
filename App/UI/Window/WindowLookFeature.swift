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
        self.window = window
        applyPageInsets(for: .sidebar, showsToolbar: true)
        window.window?.backgroundColor = BowBrand.frame
        let soft = BowBrand.softShadow()
        window.pageShadow = PageShadow(
            color: soft.shadowColor ?? .clear, radius: soft.shadowBlurRadius, offset: soft.shadowOffset,
            fill: BowBrand.page)
        if let content = window.window?.contentView {
            dragArea.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(dragArea, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                dragArea.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                dragArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                dragArea.topAnchor.constraint(equalTo: content.topAnchor),
                dragArea.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
    }

    /// The frame behind everything else in the window, which drags the window as a title bar does.
    let dragArea = WindowDragArea()

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private weak var window: BrowserWindowController?
    private var placedNavigation = false

    /// The page card's insets for `layout` (`WindowLayout.pageInsets`): the top tabs layout leaves room above the card
    /// for the tab strip and the toolbar row (the sidebar layout's leading edge meets the sidebar instead).
    func applyPageInsets(for layout: WindowLayout, showsToolbar: Bool) {
        let insets = layout.pageInsets(showsToolbar: showsToolbar)
        window?.pageInsets = NSEdgeInsets(
            top: insets.top, left: insets.leading, bottom: insets.bottom, right: insets.trailing)
    }

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

/// The window's Frame colored surface behind the sidebar and the page card: a press on it drags the window, as on a
/// title bar. It sits behind every other view of the window, so it only gets the presses nothing else takes (the
/// inset around the page card), never one meant for the page or a control.
@MainActor
final class WindowDragArea: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            performTitleBarDoubleClick(on: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// What a title bar double click does per System Settings (AppleActionOnDoubleClick): zoom by default.
    func performTitleBarDoubleClick(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}
