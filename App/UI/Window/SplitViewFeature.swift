import AppKit
import BowCore

/// Split view as a sidebar item, as Arc has it: two to four tabs saved as one split in the sidebar, shown side by side
/// in the page area.
///
/// Selecting a tab of a split (or the split's row, which selects its focused tab) shows all of its tabs as panes with
/// that tab focused; selecting any other tab shows that tab alone, and selecting the split again brings its panes back
/// with the focus it had. Dragging a divider saves the panes' widths in the split. Each pane has a close button at its
/// top trailing corner that takes it out of the split, leaving its tab as a plain tab right after the split (a split
/// left with one tab turns back into that tab). View > Add Split View (Cmd+Shift+plus, Arc's shortcut) opens a new
/// tab as a pane beside the shown one; the sidebar's "Open in Split View" and "Separate All Tabs" are in
/// `SplitViewMenuItems`. `SplitViewDisplay` decides when the panes change; this feature only applies it.
@MainActor
final class SplitViewFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController
    private var display = SplitViewDisplay()
    /// True while this feature changes the panes, so the window's update it causes does not ask again.
    private var arranging = false
    /// One close button per pane while a split shows, leading to trailing.
    private var closeButtons: [SplitPaneCloseButton] = []
    /// The pane views whose frame changes move the close buttons.
    private var observedPanes: [NSView] = []

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func addMenuItems(to menus: MainMenu.Menus) {
        if !menus.view.items.isEmpty { menus.view.addItem(.separator()) }
        // "+" with Shift held: Cmd+Shift+plus, which is Cmd+Shift+= on a US keyboard.
        let item = menus.view.addItem(
            withTitle: "Add Split View", action: #selector(addSplitView(_:)), keyEquivalent: "+")
        item.keyEquivalentModifierMask = [.command, .shift]
    }

    // MARK: Commands

    /// View > Add Split View: opens a new tab as a pane beside the shown tab, focused, in a new split or in the shown
    /// tab's split.
    @objc func addSplitView(_ sender: Any?) {
        let graph = window.store.graph
        guard !window.isClosing, let placement = graph.newPanePlacement(besides: graph.activeTabID),
            let tab = window.openTab(url: window.newTabURL, select: false), let id = window.modelID(of: tab),
            let item = window.sidebarItemID(for: id)
        else { return }
        window.changeSidebar { store in
            switch placement {
            case .createWith(let active): try store.createSplit(from: [active, item], focusing: item)
            case .addPane(let split): try store.addPane(item, to: split)
            }
            try store.selectTab(item)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(addSplitView(_:)):
            !window.isClosing && window.store.graph.newPanePlacement(besides: window.store.graph.activeTabID) != nil
        default: true
        }
    }

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard KeyShortcuts.shortcut(for: event, claimedBy: .splitView) == .addSplitView else { return false }
        // The key is ours even when no pane can be added, so the page never sees it.
        addSplitView(nil)
        return true
    }

    // MARK: Following the sidebar

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        // Only while the active tab's page is open: when it is not (the window's last page closed, quitting, a pinned
        // tab kept unloaded), showing the panes would load pages the window is letting go of.
        guard let tab, !tab.isClosed, !window.isClosing else {
            removeCloseButtons()
            return
        }
        arrange()
    }

    func paneDividerMoved(fractions: [Double]) {
        placeCloseButtons()
        guard let splitID = display.splitID, display.shown == window.store.graph.splitPaneIDs(splitID) else { return }
        // Straight to the store, not through `changeSidebar`: the window already shows these widths, and laying the
        // panes out again in the middle of the drag would fight it. Only the split's widths change.
        do {
            try window.store.setSplitWidthFactors(splitID, fractions)
        } catch {
            FileHandle.standardError.write(Data("bow: the split's widths were not saved: \(error)\n".utf8))
        }
    }

    /// Brings the panes in step with the sidebar's splits, as `SplitViewDisplay` decides.
    private func arrange() {
        guard !arranging else { return }
        arranging = true
        defer { arranging = false }
        let action = display.update(graph: window.store.graph, shownNow: shownItems)
        switch action {
        case .none:
            break
        case .show(let plan):
            let ids = runtimeIDs(plan.panes)
            if let ids, let focused = runtimeIDs([plan.focused])?.first {
                window.showPanes(ids, focused: focused, fractions: plan.fractions)
            }
        case .single(let item):
            if let id = runtimeIDs([item])?.first { window.showPanes([id], focused: id) }
        }
        display.record(shown: shownItems)
        updateCloseButtons()
    }

    /// The sidebar tabs the panes show, in pane order.
    private var shownItems: [SidebarItemID] {
        window.shownTabs.compactMap { window.modelID(of: $0).flatMap(window.sidebarItemID(for:)) }
    }

    /// The window's runtime IDs of sidebar tabs `items`, nil unless the window lists every one.
    private func runtimeIDs(_ items: [SidebarItemID]) -> [BrowserTabID]? {
        var byItem: [SidebarItemID: BrowserTabID] = [:]
        for tab in window.tabList.tabs {
            if let item = window.sidebarItemID(for: tab.id) { byItem[item] = tab.id }
        }
        let ids = items.compactMap { byItem[$0] }
        return ids.count == items.count ? ids : nil
    }

    // MARK: Pane close buttons

    /// Takes the pane of `item` out of its split, leaving the tab as a plain tab right after the split.
    func removePane(_ item: SidebarItemID) {
        guard !window.isClosing, window.store.graph.splitID(containing: item) != nil else { return }
        window.changeSidebar { try $0.removePane(item) }
    }

    /// The panes' close buttons, leading to trailing, for the tabs they remove; empty while no split shows.
    var paneCloseButtons: [(button: NSButton, item: SidebarItemID)] {
        closeButtons.map { ($0, $0.item) }
    }

    /// Takes every close button away and stops following the panes' frames.
    private func removeCloseButtons() {
        for button in closeButtons { button.removeFromSuperview() }
        closeButtons.removeAll()
        observe([])
    }

    /// One close button per pane while the panes show a split, none otherwise.
    private func updateCloseButtons() {
        let items = display.splitID == nil ? [] : display.shown
        let panes = window.paneViews
        guard items.count > 1, items.count == panes.count else {
            removeCloseButtons()
            return
        }
        while closeButtons.count > items.count { closeButtons.removeLast().removeFromSuperview() }
        for (index, item) in items.enumerated() {
            if index < closeButtons.count {
                closeButtons[index].item = item
            } else {
                let button = SplitPaneCloseButton(item: item) { [weak self] item in self?.removePane(item) }
                closeButtons.append(button)
            }
            // Above the panes, which the window keeps at the back of the page area.
            if closeButtons[index].superview !== window.pageArea {
                window.pageArea.addSubview(closeButtons[index], positioned: .above, relativeTo: nil)
            }
        }
        observe(panes)
        placeCloseButtons()
    }

    /// Follows the frames of `panes`, which change when the window resizes or a divider moves.
    private func observe(_ panes: [NSView]) {
        guard !panes.elementsEqual(observedPanes, by: ===) else { return }
        for view in observedPanes {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: view)
        }
        for view in panes {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(paneFrameChanged(_:)), name: NSView.frameDidChangeNotification, object: view)
        }
        observedPanes = panes
    }

    @objc private func paneFrameChanged(_ notification: Notification) {
        placeCloseButtons()
    }

    /// Puts each close button at its pane's top trailing corner.
    private func placeCloseButtons() {
        let panes = window.paneViews
        guard panes.count == closeButtons.count else { return }
        let area = window.pageArea
        for (button, pane) in zip(closeButtons, panes) {
            let frame = pane.convert(pane.bounds, to: area)
            let size = SplitPaneCloseButton.size
            let inset = SplitPaneCloseButton.inset
            let top = area.isFlipped ? frame.minY + inset : frame.maxY - inset - size
            button.frame = NSRect(x: frame.maxX - inset - size, y: top, width: size, height: size)
        }
    }
}

/// A pane's close button: a small round "x" that takes its pane out of the split.
final class SplitPaneCloseButton: NSButton {
    static let size: CGFloat = 18
    static let inset: CGFloat = 8

    /// The tab of the pane the button removes.
    var item: SidebarItemID
    private let onPress: (SidebarItemID) -> Void

    init(item: SidebarItemID, onPress: @escaping (SidebarItemID) -> Void) {
        self.item = item
        self.onPress = onPress
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove from Split View")
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        contentTintColor = .secondaryLabelColor
        toolTip = "Remove from Split View"
        setAccessibilityLabel("Remove from Split View")
        target = self
        action = #selector(pressed(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func pressed(_ sender: Any?) {
        onPress(item)
    }
}
