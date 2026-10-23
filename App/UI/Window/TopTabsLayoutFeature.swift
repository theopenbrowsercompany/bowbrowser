import AppKit
import BowCore

/// View > Use Top Tabs: switches every window between the sidebar layout (the default) and the compact top tabs
/// layout, a setting (`AppSettings.windowLayout`) that is saved and that every open window follows at once.
///
/// In the top tabs layout the sidebar is out of the window (its view stays alive and keeps following the store, so
/// switching back restores it exactly as it was), and above the page card sit a tab strip row (`WindowLayout.tabStripHeight`
/// high, the window buttons at its leading edge; a later slice fills it with tabs) and the toolbar row
/// (`WindowLayout.toolbarRowHeight` high): back, forward and reload, the URL field, and the Space dots. The row reuses
/// the same views the sidebar layout has (`NavigationToolbar`, `URLFieldView`, `SpaceSwitcher`), so Cmd+L, the command
/// bar, Copy Current URL and Space switching work the same in both. View > Hide Toolbar hides the row here too.
@MainActor
final class TopTabsLayoutFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController

    /// The tab strip row, reserved for the tab pills.
    let strip = NSView()
    /// The toolbar row: navigation buttons, the URL field and the Space dots.
    let toolbarRow = NSStackView()
    /// Both rows, over the window's content from its top edge.
    private let bar = TopBarView()
    let urlField = URLFieldView()
    let spaces = SpaceSwitcher()
    private(set) var layout = WindowLayout.sidebar
    private var barConstraints: [NSLayoutConstraint] = []
    private var applied = false
    /// Where the system put the window buttons, and how tall it made their title bar, before this layout moved them.
    private var originalButtons: [NSWindow.ButtonType: NSPoint] = [:]
    private var originalTitlebarHeight: CGFloat = 0
    private var movedButtons = false

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(settingChanged(_:)), name: AppSettings.windowLayoutChanged, object: nil)
        center.addObserver(
            self, selector: #selector(settingChanged(_:)), name: AppSettings.toolbarVisibilityChanged, object: nil)
        center.addObserver(
            self, selector: #selector(placeWindowButtons(_:)), name: NSWindow.didResizeNotification,
            object: window.window)
        center.addObserver(
            self, selector: #selector(placeWindowButtons(_:)), name: NSWindow.didExitFullScreenNotification,
            object: window.window)
        buildBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.view.addItem(.separator())
        menus.view.addItem(withTitle: WindowLayout.menuTitle, action: #selector(toggleTopTabs(_:)), keyEquivalent: "")
    }

    @objc func toggleTopTabs(_ sender: Any?) {
        AppSettings.windowLayout = AppSettings.windowLayout.toggled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTopTabs(_:)) {
            menuItem.state = AppSettings.windowLayout == .topTabs ? .on : .off
        }
        return true
    }

    // MARK: Following the window

    /// Called once as the window opens, after every feature exists, so the sidebar and the navigation buttons are there.
    func activeSpaceChanged(_ space: SidebarSpace) {
        apply()
        refresh()
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) { refresh() }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        if case .stateChanged = event { refresh() }
    }

    func storeChanged(_ graph: SidebarGraph) { refresh() }

    @objc private func settingChanged(_ notification: Notification) {
        apply()
        refresh()
    }

    /// Shows the shown tab's site in the URL field and the window's Spaces in the dots.
    private func refresh() {
        guard layout == .topTabs else { return }
        let list = window.tabList
        let url = list.activeID.flatMap { id in list.tabs.first { $0.id == id } }?.url
        urlField.show(AddressDisplay.text(for: url))
        let sidebar = window.feature(SidebarFeature.self)
        spaces.update(
            content: SidebarContent(graph: window.store.graph, tabs: [:], activeItem: nil), context: sidebar)
    }

    // MARK: Layout

    private func apply() {
        let wanted = AppSettings.windowLayout
        guard !applied || wanted != layout else {
            // The toolbar setting changes the card's top inset in this layout.
            if layout == .topTabs { applyChrome() }
            return
        }
        applied = true
        layout = wanted
        let top = wanted == .topTabs
        window.feature(SidebarFeature.self)?.setHidden(top)
        bar.isHidden = !top
        placeNavigation()
        applyChrome()
        placeWindowButtons(nil)
    }

    /// The toolbar row and the card's insets, which follow the layout and View > Hide Toolbar.
    private func applyChrome() {
        let showsToolbar = AppSettings.showsToolbar
        toolbarRow.isHidden = !showsToolbar
        window.feature(WindowLookFeature.self)?.applyPageInsets(for: layout, showsToolbar: showsToolbar)
    }

    /// The back, forward and reload buttons live in the sidebar's top row in the sidebar layout and in the toolbar row
    /// in this one.
    private func placeNavigation() {
        guard let navigation = window.feature(NavigationFeature.self)?.toolbar.view,
            let sidebar = window.feature(SidebarFeature.self)?.sidebar
        else { return }
        navigation.removeFromSuperview()
        if layout == .topTabs {
            navigation.spacing = CGFloat(WindowLayout.itemGap)
            toolbarRow.insertArrangedSubview(navigation, at: 0)
        } else {
            navigation.spacing = 4
            sidebar.topRow.addArrangedSubview(navigation)
        }
    }

    private func buildBar() {
        guard let content = window.window?.contentView else { return }
        let gap = CGFloat(WindowLayout.itemGap)
        let padding = CGFloat(WindowLayout.rowPadding)
        bar.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        toolbarRow.translatesAutoresizingMaskIntoConstraints = false
        toolbarRow.orientation = .horizontal
        toolbarRow.alignment = .centerY
        toolbarRow.spacing = gap
        toolbarRow.edgeInsets = NSEdgeInsets(top: 0, left: padding, bottom: 0, right: padding)
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let stack = spaces.view as? NSStackView {
            // The sidebar footer's top padding would push the dots off the row's center.
            stack.edgeInsets = NSEdgeInsetsZero
            stack.setContentHuggingPriority(.required, for: .horizontal)
            stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        toolbarRow.addArrangedSubview(urlField)
        toolbarRow.addArrangedSubview(spaces.view)
        bar.addSubview(strip)
        bar.addSubview(toolbarRow)
        content.addSubview(bar, positioned: .above, relativeTo: nil)
        bar.isHidden = true
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            strip.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            strip.topAnchor.constraint(equalTo: bar.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: CGFloat(WindowLayout.tabStripHeight)),
            toolbarRow.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            toolbarRow.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            toolbarRow.topAnchor.constraint(equalTo: strip.bottomAnchor),
            toolbarRow.heightAnchor.constraint(equalToConstant: CGFloat(WindowLayout.toolbarRowHeight)),
            urlField.heightAnchor.constraint(equalToConstant: CGFloat(WindowLayout.urlFieldHeight)),
            bar.bottomAnchor.constraint(equalTo: toolbarRow.bottomAnchor),
        ])
    }

    // MARK: Window buttons

    /// Puts the close, minimize and zoom buttons at the tab strip's leading edge, centered in it, in the top tabs
    /// layout, and back where the system had them otherwise. Left alone in full screen, which has no title bar.
    @objc private func placeWindowButtons(_ notification: Notification?) {
        guard let nswindow = window.window, !nswindow.styleMask.contains(.fullScreen) else { return }
        // The sidebar layout leaves the system's placement alone until this layout has moved the buttons.
        guard layout == .topTabs || movedButtons else { return }
        movedButtons = layout == .topTabs
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = kinds.compactMap { kind in nswindow.standardWindowButton(kind).map { (kind, $0) } }
        guard let first = buttons.first?.1, let titlebar = first.superview, let container = titlebar.superview else {
            return
        }
        if originalButtons.isEmpty {
            for (kind, button) in buttons { originalButtons[kind] = button.frame.origin }
            originalTitlebarHeight = container.frame.height
        }
        let spacing = buttons.count > 1 ? buttons[1].1.frame.minX - first.frame.minX : 20
        let stripHeight = CGFloat(WindowLayout.tabStripHeight)
        if let frameView = container.superview {
            // The title bar grows to the strip's height, from the window's top edge, so the buttons can sit in its
            // middle and still take clicks; it goes back to the system's height with the sidebar layout.
            let height = layout == .topTabs ? stripHeight : originalTitlebarHeight
            container.frame = NSRect(
                x: 0, y: frameView.bounds.height - height, width: frameView.bounds.width, height: height)
            titlebar.frame = container.bounds
        }
        for (index, (kind, button)) in buttons.enumerated() {
            var origin = originalButtons[kind] ?? button.frame.origin
            if layout == .topTabs {
                origin.x = CGFloat(WindowLayout.rowPadding) + CGFloat(index) * spacing
                origin.y = (stripHeight - button.frame.height) / 2
            }
            button.setFrameOrigin(origin)
        }
    }
}

/// The two rows' container: it takes only the presses on the controls inside it, so a press on the empty strip or
/// row reaches the window's drag area behind it.
@MainActor
private final class TopBarView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
