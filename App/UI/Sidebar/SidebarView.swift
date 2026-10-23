import AppKit
import BowCore

/// What the sidebar view asks of its window beyond the actions every sidebar action may take.
@MainActor
protocol SidebarViewDelegate: SidebarActionContext {
    /// The New Tab button was clicked.
    func sidebarNewTab()
    /// The site icon loaded for tab `item`, or nil while there is none.
    func favicon(for item: SidebarItemID) -> NSImage?
}

/// What the sidebar shows: the window's sidebar, what each listed tab's page last reported, and the active tab.
struct SidebarContent {
    var graph: SidebarGraph
    /// The live state of each tab of the Space on screen; other tabs (Favorites) show their saved page.
    var tabs: [SidebarItemID: BrowserTab]
    var activeItem: SidebarItemID?
}

/// One row of the outline: a section's header, or a sidebar item. Kept per key across reloads, so the outline sees
/// the same object for the same row.
@MainActor
final class SidebarNode: NSObject {
    enum Key: Hashable {
        /// The section at this index of `SidebarSections.all`.
        case section(Int)
        case item(SidebarItemID)
    }

    let key: Key
    fileprivate(set) var children: [SidebarNode] = []
    fileprivate(set) weak var parent: SidebarNode?

    init(key: Key) { self.key = key }

    var itemID: SidebarItemID? {
        if case .item(let id) = key { return id }
        return nil
    }
}

/// The vertical sidebar on the left of a window: a New Tab button above an outline of sections (`SidebarSections`):
/// the Favorites area, the pinned tabs with their folders, a divider and today's tabs. Each tab row shows its site
/// icon (a spinner while it loads), its title and, on hover or when active, a close button; the active tab's row is
/// highlighted. Rows can be dragged within and across pinned and today (`SidebarDrop`), and right-clicking a row
/// shows its kind's menu items (`SidebarMenus`). The footer below the outline is empty, kept for footer controls.
@MainActor
final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let width: CGFloat = 240
    private static let rowHeight: CGFloat = 32
    private static let dragType = NSPasteboard.PasteboardType("dev.bowbrowser.sidebar-item")

    weak var delegate: (any SidebarViewDelegate)?
    let newTabButton: NSButton
    let outlineView = NSOutlineView()
    /// Controls along the bottom edge (the archive button); empty for now, and then it takes no room.
    let footer = NSStackView()
    private let sections = SidebarSections.all.map { $0.init() }
    private(set) var content = SidebarContent(graph: .fresh(), tabs: [:], activeItem: nil)
    private var roots: [SidebarNode] = []
    private var nodes: [SidebarNode.Key: SidebarNode] = [:]
    /// The section node listing each container on screen.
    private var containerNodes: [SidebarItemID: SidebarNode] = [:]
    /// The container each section lists, by section index; nil for a section without items.
    private var sectionContainers: [SidebarItemID?] = []
    /// The rows' keys and depths last shown, to tell a change of shape from a change of contents. Folders' open
    /// states are not part of it: opening or closing one is synced without rebuilding the rows.
    private var shape: [String] = []
    /// True while the view opens and closes rows itself, so those are not taken for the person's.
    private var isSyncing = false

    override init(frame: NSRect) {
        newTabButton = NSButton(
            title: "New Tab", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil) ?? NSImage(),
            target: nil, action: nil)
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 10
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.backgroundColor = .clear
        outlineView.allowsEmptySelection = true
        outlineView.allowsMultipleSelection = false
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineClicked(_:))
        outlineView.registerForDraggedTypes([Self.dragType])
        outlineView.draggingDestinationFeedbackStyle = .gap
        outlineView.setAccessibilityLabel("Tabs")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)

        for view in [background, newTabButton, scrollView, footer] as [NSView] {
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
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Showing the sidebar

    /// Shows `content`: the sections of the Space on screen, with the active tab highlighted. Rows are rebuilt only
    /// when the sidebar's shape changed; otherwise only the rows whose contents changed are redrawn.
    func show(_ content: SidebarContent) {
        let previous = self.content
        self.content = content
        let newShape = rebuildNodes()
        isSyncing = true
        defer { isSyncing = false }
        if newShape != shape {
            shape = newShape
            outlineView.reloadData()
            syncExpansion(roots)
        } else {
            // A folder opened or closed (or a refused change put it back) keeps its rows; only its state syncs.
            syncExpansion(roots)
            let changed = IndexSet(
                (0..<outlineView.numberOfRows).filter { row in
                    guard let id = (outlineView.item(atRow: row) as? SidebarNode)?.itemID else { return false }
                    return previous.tabs[id] != content.tabs[id] || previous.graph[id] != content.graph[id]
                })
            if !changed.isEmpty { outlineView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        }
        syncSelection()
        refreshActiveMarks()
    }

    /// Redraws the row of tab `item`, for a change the content does not hold (its site icon loaded).
    func reloadItem(_ item: SidebarItemID) {
        guard let row = row(for: item) else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    /// The outline row showing `item`, nil while it is hidden in a closed folder or not in the sidebar.
    func row(for item: SidebarItemID) -> Int? {
        guard let node = nodes[.item(item)] else { return nil }
        let row = outlineView.row(forItem: node)
        return row >= 0 ? row : nil
    }

    /// The row view showing tab `item`, while it is on screen in the outline.
    func rowView(for item: SidebarItemID) -> TabSidebarRow? {
        guard let row = row(for: item) else { return nil }
        return outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarRow
    }

    /// What each row is, top to bottom: a section header (with its zone, nil for the divider) or an item.
    func rowKinds() -> [(section: (any SidebarSection)?, item: SidebarItemID?)] {
        (0..<outlineView.numberOfRows).map { row in
            switch (outlineView.item(atRow: row) as? SidebarNode)?.key {
            case .section(let index)?: return (sections[index], nil)
            case .item(let id)?: return (nil, id)
            case nil: return (nil, nil)
            }
        }
    }

    /// The zone `item` is in on screen, nil when it is in no section shown.
    func zone(of item: SidebarItemID) -> SidebarZone? {
        var node = nodes[.item(item)]
        while let current = node {
            if case .section(let index) = current.key { return sections[index].zone }
            node = current.parent
        }
        return nil
    }

    /// Builds the nodes for the current content and returns its shape.
    private func rebuildNodes() -> [String] {
        let graph = content.graph
        var shape: [String] = []
        var used: [SidebarNode.Key: SidebarNode] = [:]
        containerNodes = [:]
        sectionContainers = []
        func node(_ key: SidebarNode.Key, parent: SidebarNode?) -> SidebarNode {
            let node = nodes[key] ?? SidebarNode(key: key)
            node.parent = parent
            used[key] = node
            return node
        }
        func children(of id: SidebarItemID, under parent: SidebarNode, depth: Int) -> [SidebarNode] {
            graph.children(of: id).filter { !$0.data.isContainer && used[.item($0.id)] == nil }.map { item in
                let child = node(.item(item.id), parent: parent)
                shape.append("\(depth) \(item.id)")
                child.children = children(of: item.id, under: child, depth: depth + 1)
                return child
            }
        }
        roots = sections.indices.map { index in
            let section = node(.section(index), parent: nil)
            shape.append("section \(index)")
            let container = graph.activeSpace.flatMap { sections[index].containerID(in: graph, space: $0) }
            sectionContainers.append(container)
            if let container {
                containerNodes[container] = section
                shape.append("container \(container)")
                section.children = children(of: container, under: section, depth: 1)
            } else {
                section.children = []
            }
            return section
        }
        nodes = used
        return shape
    }

    /// Opens every section and split and each folder the sidebar has open, and closes the others.
    private func syncExpansion(_ nodes: [SidebarNode]) {
        for node in nodes {
            if isOpen(node) {
                if !outlineView.isItemExpanded(node) { outlineView.expandItem(node) }
                syncExpansion(node.children)
            } else if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            }
        }
    }

    /// Whether `node`'s row shows its contents: a folder as the sidebar saved it, every section and split always.
    private func isOpen(_ node: SidebarNode) -> Bool {
        guard let id = node.itemID else { return true }
        if case .folder(let folder)? = content.graph[id]?.data { return folder.isExpanded }
        return true
    }

    private func syncSelection() {
        let wanted = content.activeItem.flatMap { row(for: $0) }.map { IndexSet(integer: $0) } ?? IndexSet()
        guard outlineView.selectedRowIndexes != wanted else { return }
        outlineView.selectRowIndexes(wanted, byExtendingSelection: false)
    }

    /// Updates which row shows itself active (its close button), after the highlight moved.
    private func refreshActiveMarks() {
        for row in 0..<outlineView.numberOfRows {
            guard let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarRow,
                let id = (outlineView.item(atRow: row) as? SidebarNode)?.itemID
            else { continue }
            view.isActive = id == content.activeItem
        }
    }

    @objc private func newTabClicked(_ sender: Any?) {
        delegate?.sidebarNewTab()
    }

    // MARK: Clicks and drops

    @objc private func outlineClicked(_ sender: Any?) {
        clickRow(outlineView.clickedRow)
    }

    /// What a click on row `row` does (the outline's click action): a tab row asks the window to make that tab
    /// active. A click on a section, folder or split row, or outside the rows, selects nothing.
    func clickRow(_ row: Int) {
        guard row >= 0, let id = (outlineView.item(atRow: row) as? SidebarNode)?.itemID,
            content.graph[id]?.data.isTab == true
        else { return }
        delegate?.select(id)
    }

    /// Drops `item` into `parent` at `index` (counted before it leaves its place), as dropping its row there does.
    /// Returns whether it moved; a drop a validator refuses changes nothing.
    @discardableResult
    func drop(_ item: SidebarItemID, into parent: SidebarItemID, at index: Int) -> Bool {
        guard let delegate else { return false }
        return SidebarDrop(item: item, parent: parent, index: index).perform(in: delegate)
    }

    /// Where a drop of `item` the outline proposes on `node` at `index` lands, nil when no rule allows it there: a
    /// container, folder or split and a position in it. A drop on a tab goes above it, a drop on the divider to the
    /// top of the section after it, a drop on a folder or split to its end, and a drop between sections to the end
    /// of the section above or, when that is refused (Favorites), the top of the one below.
    private func dropTarget(of item: SidebarItemID, on node: SidebarNode?, index: Int) -> SidebarDrop? {
        dropCandidates(on: node, index: index).lazy
            .map { SidebarDrop(item: item, parent: $0.parent, index: $0.index) }
            .first { SidebarDropValidators.allows($0, in: self.content.graph) }
    }

    /// The places a proposed drop may land, in order of preference.
    private func dropCandidates(on node: SidebarNode?, index: Int) -> [(parent: SidebarItemID, index: Int)] {
        let graph = content.graph
        guard let node else {
            var candidates: [(parent: SidebarItemID, index: Int)] = []
            if index > 0, let above = container(ofSection: index - 1) {
                candidates.append((above, graph[above]?.childrenIDs.count ?? 0))
            }
            if roots.indices.contains(index) { candidates += dropCandidates(on: roots[index], index: 0) }
            return candidates
        }
        switch node.key {
        case .section(let position):
            if let container = container(ofSection: position) {
                return [(container, index < 0 ? 0 : index)]
            }
            // The divider: the top of the next section that lists items.
            for next in (position + 1)..<roots.count {
                if let container = container(ofSection: next) { return [(container, 0)] }
            }
            return []
        case .item(let id):
            guard let item = graph[id] else { return [] }
            if item.data.isTab {
                guard index < 0, let parent = item.parentID,
                    let position = graph[parent]?.childrenIDs.firstIndex(of: id)
                else { return [] }
                return [(parent, position)]
            }
            return [(id, index < 0 ? item.childrenIDs.count : index)]
        }
    }

    private func container(ofSection index: Int) -> SidebarItemID? {
        sectionContainers.indices.contains(index) ? sectionContainers[index] : nil
    }

    private func outlineNode(for parent: SidebarItemID) -> SidebarNode? {
        containerNodes[parent] ?? nodes[.item(parent)]
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .section = node.key { return true }
        return node.itemID.flatMap { content.graph[$0] }.map { !$0.data.isTab } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        guard let id = (item as? SidebarNode)?.itemID, case .folder? = content.graph[id]?.data else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard let id = (item as? SidebarNode)?.itemID, case .folder? = content.graph[id]?.data else {
            return isSyncing
        }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard case .section(let index)? = (item as? SidebarNode)?.key else { return Self.rowHeight }
        return max(sections[index].headerHeight, 1)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.key {
        case .section(let index):
            return sections[index].makeHeaderView()
        case .item(let id):
            guard let item = content.graph[id] else { return nil }
            guard let saved = item.tab else {
                let view =
                    outlineView.makeView(withIdentifier: SidebarGroupRow.identifier, owner: nil) as? SidebarGroupRow
                    ?? SidebarGroupRow()
                view.show(item)
                return view
            }
            var tab = content.tabs[id] ?? BrowserTab(url: saved.savedPageURL, title: saved.savedTitle)
            if let custom = item.title, !custom.isEmpty { tab.title = custom }
            let view =
                outlineView.makeView(withIdentifier: TabSidebarRow.identifier, owner: nil) as? TabSidebarRow
                ?? TabSidebarRow()
            view.show(tab, favicon: delegate?.favicon(for: id), isActive: id == content.activeItem)
            // Only the Space's own tabs close from their row; a Favorite's actions come with the Favorites grid.
            view.isClosable = content.tabs[id] != nil
            view.onClose = { [weak self] in self?.delegate?.close(id) }
            return view
        }
    }

    /// The outline never changes its highlight on its own: pressing on a row may start a drag, which must not make
    /// that tab active. The highlight follows the content, and a click selects through `clickRow(_:)`.
    func outlineView(
        _ outlineView: NSOutlineView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        outlineView.selectedRowIndexes
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        folder(notification, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        folder(notification, expanded: false)
    }

    /// Saves a folder the person opened or closed with its triangle.
    private func folder(_ notification: Notification, expanded: Bool) {
        guard !isSyncing, let node = notification.userInfo?["NSObject"] as? SidebarNode, let id = node.itemID,
            case .folder(let folder)? = content.graph[id]?.data, folder.isExpanded != expanded
        else { return }
        delegate?.changeSidebar { try $0.apply([.setFolderExpanded(id, expanded)]) }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let id = (item as? SidebarNode)?.itemID else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(id.rawValue, forType: Self.dragType)
        return writer
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outlineView, let id = draggedItem(info),
            let target = dropTarget(of: id, on: item as? SidebarNode, index: index),
            let node = outlineNode(for: target.parent)
        else { return [] }
        outlineView.setDropItem(node, dropChildIndex: target.index)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let id = draggedItem(info), let target = dropTarget(of: id, on: item as? SidebarNode, index: index)
        else { return false }
        return drop(id, into: target.parent, at: target.index)
    }

    private func draggedItem(_ info: any NSDraggingInfo) -> SidebarItemID? {
        info.draggingPasteboard.string(forType: Self.dragType).map { SidebarItemID($0) }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let id = (outlineView.item(atRow: row) as? SidebarNode)?.itemID, let delegate else { return }
        for item in SidebarMenus.menu(for: id, context: delegate) { menu.addItem(item) }
    }
}
