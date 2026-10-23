import AppKit
import BowCore

/// What the sidebar asks its window to do. The sidebar only shows the tab list; the window changes it.
@MainActor
protocol TabSidebarDelegate: AnyObject {
    func sidebar(_ sidebar: TabSidebarView, select id: BrowserTabID)
    func sidebar(_ sidebar: TabSidebarView, close id: BrowserTabID)
    func sidebar(_ sidebar: TabSidebarView, move id: BrowserTabID, to index: Int)
    func sidebarNewTab(_ sidebar: TabSidebarView)
    /// The site icon loaded for a tab, or nil while there is none.
    func sidebar(_ sidebar: TabSidebarView, faviconFor id: BrowserTabID) -> NSImage?
}

/// The vertical sidebar on the left of a window: a New Tab button above the window's tabs, each row showing the
/// tab's site icon (a spinner while it loads), its title and, on hover or when active, a close button. The active
/// tab's row is highlighted. Rows can be dragged to reorder the tabs.
@MainActor
final class TabSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 240
    private static let rowHeight: CGFloat = 32
    private static let dragType = NSPasteboard.PasteboardType("dev.bowbrowser.sidebar-tab")

    weak var delegate: (any TabSidebarDelegate)?
    let newTabButton: NSButton
    let tableView = NSTableView()
    private(set) var tabList = TabList()

    override init(frame: NSRect) {
        newTabButton = NSButton(title: "New Tab", image: Self.symbol("plus"), target: nil, action: nil)
        super.init(frame: frame)

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        newTabButton.target = self
        newTabButton.action = #selector(newTabClicked(_:))
        newTabButton.isBordered = false
        newTabButton.imagePosition = .imageLeading
        newTabButton.alignment = .left
        newTabButton.contentTintColor = .secondaryLabelColor
        newTabButton.font = .systemFont(ofSize: 13)
        newTabButton.setAccessibilityLabel("New Tab")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(tableClicked(_:))
        tableView.registerForDraggedTypes([Self.dragType])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.setAccessibilityLabel("Tabs")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        for view in [background, newTabButton, scrollView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            newTabButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            newTabButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            newTabButton.heightAnchor.constraint(equalToConstant: 28),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: newTabButton.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `list`: its tabs in order, with its active tab highlighted.
    func show(_ list: TabList) {
        let structureChanged = list.tabs.map(\.id) != tabList.tabs.map(\.id)
        let previous = tabList
        tabList = list
        if structureChanged {
            tableView.reloadData()
        } else {
            let changed = IndexSet(list.tabs.indices.filter { list.tabs[$0] != previous.tabs[$0] })
            if !changed.isEmpty { tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        }
        syncSelection()
        refreshActiveMarks()
    }

    /// Redraws the row of tab `id`, for a change the tab list does not hold (its site icon loaded).
    func reloadTab(_ id: BrowserTabID) {
        guard let row = tabList.index(of: id) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    /// The row view showing tab `id`, while it is on screen in the table.
    func rowView(for id: BrowserTabID) -> TabSidebarRow? {
        guard let row = tabList.index(of: id) else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarRow
    }

    private func syncSelection() {
        let wanted = tabList.activeIndex.map { IndexSet(integer: $0) } ?? IndexSet()
        guard tableView.selectedRowIndexes != wanted else { return }
        tableView.selectRowIndexes(wanted, byExtendingSelection: false)
    }

    @objc private func newTabClicked(_ sender: Any?) {
        delegate?.sidebarNewTab(self)
    }

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tabList.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tab = tabList.tabs[row]
        let view =
            tableView.makeView(withIdentifier: TabSidebarRow.identifier, owner: nil) as? TabSidebarRow
            ?? TabSidebarRow()
        view.show(
            tab,
            favicon: delegate?.sidebar(self, faviconFor: tab.id),
            isActive: tab.id == tabList.activeID
        )
        view.onClose = { [weak self] in
            guard let self else { return }
            self.delegate?.sidebar(self, close: tab.id)
        }
        return view
    }

    /// The table never changes its highlight on its own: pressing on a row may start a drag, which must not make
    /// that tab active. The highlight follows the tab list, and a click selects through `clickRow(_:)`.
    func tableView(
        _ tableView: NSTableView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        tableView.selectedRowIndexes
    }

    @objc private func tableClicked(_ sender: Any?) {
        clickRow(tableView.clickedRow)
    }

    /// What a click on row `row` does (the table's click action): asks the window to make that tab active. A click
    /// outside the rows does nothing.
    func clickRow(_ row: Int) {
        guard tabList.tabs.indices.contains(row) else { return }
        delegate?.sidebar(self, select: tabList.tabs[row].id)
    }

    /// Updates which row shows itself active (its close button), after the highlight moved.
    private func refreshActiveMarks() {
        for (row, tab) in tabList.tabs.enumerated() {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarRow)?.isActive =
                tab.id == tabList.activeID
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(tabList.tabs[row].id.rawValue.uuidString, forType: Self.dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let string = info.draggingPasteboard.string(forType: Self.dragType),
            let uuid = UUID(uuidString: string),
            let from = tabList.index(of: BrowserTabID(rawValue: uuid))
        else { return false }
        // `row` is a gap in the order before the move; the tab list wants the position after it.
        let destination = row > from ? row - 1 : row
        delegate?.sidebar(self, move: tabList.tabs[from].id, to: destination)
        return true
    }
}

/// One tab's row in the sidebar.
@MainActor
final class TabSidebarRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TabSidebarRow")

    let titleField = NSTextField(labelWithString: "")
    let iconView = NSImageView()
    let spinner = NSProgressIndicator()
    let closeButton: NSButton
    var onClose: (() -> Void)?
    var isActive = false {
        didSet { updateCloseButton() }
    }
    private var isHovered = false {
        didSet { updateCloseButton() }
    }

    init() {
        let xmark = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab") ?? NSImage()
        closeButton = NSButton(image: xmark, target: nil, action: nil)
        super.init(frame: .zero)
        identifier = Self.identifier

        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: 13)
        titleField.cell?.usesSingleLineMode = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleField

        iconView.imageScaling = .scaleProportionallyUpOrDown
        imageView = iconView

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")

        for view in [iconView, spinner, titleField, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `tab`: its icon (or a spinner while loading, or a globe without an icon) and its title.
    func show(_ tab: BrowserTab, favicon: NSImage?, isActive: Bool) {
        titleField.stringValue = Self.displayTitle(of: tab)
        toolTip = titleField.stringValue
        iconView.image =
            favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.contentTintColor = favicon == nil ? .secondaryLabelColor : nil
        hasFavicon = favicon != nil
        if tab.isLoading {
            iconView.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            iconView.isHidden = false
        }
        isLoading = tab.isLoading
        self.isActive = isActive
    }

    /// True while the row shows the spinner.
    private(set) var isLoading = false
    /// True while the row shows the site's own icon rather than the placeholder.
    private(set) var hasFavicon = false

    /// The page title, or its address before it has one, or "New Tab" before anything loaded.
    static func displayTitle(of tab: BrowserTab) -> String {
        if !tab.title.isEmpty { return tab.title }
        if let url = tab.url { return url.host ?? url.absoluteString }
        return "New Tab"
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    private func updateCloseButton() {
        closeButton.isHidden = !(isActive || isHovered)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only the row's own area: AppKit adds others (for the tooltip) that must stay.
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// The tracking area for hovering, which follows the row's visible rect by itself.
    private var hoverArea: NSTrackingArea?

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        onClose = nil
    }
}
