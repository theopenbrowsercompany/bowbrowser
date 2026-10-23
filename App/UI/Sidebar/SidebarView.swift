import AppKit
import BowCore

/// What the sidebar view asks of its window beyond the actions every sidebar action may take.
@MainActor
protocol SidebarViewDelegate: SidebarActionContext {
    /// The New Tab button was clicked.
    func sidebarNewTab()
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
/// shows its kind's menu items (`SidebarMenus`), a section header's its zone's. Accessories (`SidebarAccessories`)
/// sit in a slot between the New Tab button and the outline and in the footer below it, tab rows can carry an
/// accessory (`SidebarRowAccessories`), a sideways two-finger swipe goes to `swipeHandler`, and
/// `slideOutline(_:change:)` slides the outline's content out for new content.
@MainActor
final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    static let width: CGFloat = 240
    private static let rowHeight: CGFloat = 32
    private static let dragType = NSPasteboard.PasteboardType("dev.bowbrowser.sidebar-item")

    weak var delegate: (any SidebarViewDelegate)?
    let newTabButton: NSButton
    let outlineView = NSOutlineView()
    /// The top accessory slot, between the New Tab button and the outline; empty, it takes no room.
    let topSlot = NSStackView()
    /// The footer accessory slot along the bottom edge (the archive button); empty, it takes no room.
    let footer = NSStackView()
    /// Gets each horizontal two-finger swipe on the outline (`SidebarSwipeHandler`), with the delegate as its context;
    /// nil leaves every scroll to the outline. The sidebar keeps it. It starts as the first accessory's
    /// `SidebarAccessory.swipeHandler`; see `SidebarSwipeHandler` for where else it may be set.
    var swipeHandler: (any SidebarSwipeHandler)? {
        didSet { connectSwipes() }
    }
    private let scrollView = SidebarScrollView()
    private let sections = SidebarSections.all.map { $0.init() }
    /// The header view each section made, by section index, kept so every show can update it.
    private var headerViews: [Int: NSView] = [:]
    /// The sections already asked for a header view, including those that gave none.
    private var askedHeaders: Set<Int> = []
    /// Each section's header row height for the content on screen, by section index.
    private var headerHeights: [CGFloat] = []
    /// True while `show(_:)` runs, which updates every header once at its end.
    private var isShowing = false
    /// True while a header, accessory or row accessory is updated outside `show(_:)`.
    private var isUpdatingSlots = false
    /// The content a `show(_:)` called while another ran (or while a slot was updated) left for the next run loop
    /// turn; nil when none is waiting.
    private var deferredContent: SidebarContent?
    /// How many `slideOutline` animations are running, and whether the view clipped and the outline's scroll view
    /// had a layer before the first began.
    private var slidesRunning = 0
    private var clipsBeforeSlides = false
    private var scrollLayerBeforeSlides = false
    private let accessories = SidebarAccessories.all.map { $0.init() }
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
    /// True while a row of this outline is being dragged, so folders the drag opens on hover are not saved open.
    private var isDragging = false

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
        outlineView.doubleAction = #selector(outlineDoubleClicked(_:))
        outlineView.registerForDraggedTypes([Self.dragType])
        outlineView.draggingDestinationFeedbackStyle = .gap
        outlineView.setAccessibilityLabel("Tabs")
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        topSlot.orientation = .vertical
        topSlot.alignment = .width
        // Empty, the slot has no height of its own; its accessories' fitting heights win over this.
        let emptyHeight = topSlot.heightAnchor.constraint(equalToConstant: 0)
        emptyHeight.priority = .defaultLow
        emptyHeight.isActive = true
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        for accessory in accessories {
            switch type(of: accessory).placement {
            case .top: topSlot.addArrangedSubview(accessory.view)
            case .footer: footer.addArrangedSubview(accessory.view)
            }
        }
        swipeHandler = accessories.lazy.compactMap(\.swipeHandler).first
        connectSwipes()

        for view in [background, newTabButton, topSlot, scrollView, footer] as [NSView] {
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
            topSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSlot.topAnchor.constraint(equalTo: newTabButton.bottomAnchor, constant: 6),
            scrollView.topAnchor.constraint(equalTo: topSlot.bottomAnchor),
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
    ///
    /// A show asked for while one runs, which a header or accessory acting on the context during its update causes,
    /// is not nested inside it: the latest such content is shown on the next run loop turn, unless a later show comes
    /// first. Until then the outline (its rows, drops, menus, `beginRename`) still shows the content before it.
    func show(_ content: SidebarContent) {
        guard !isShowing, !isUpdatingSlots else {
            let scheduled = deferredContent != nil
            deferredContent = content
            if !scheduled {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let next = self.deferredContent else { return }
                    self.deferredContent = nil
                    self.show(next)
                }
            }
            return
        }
        deferredContent = nil
        let previous = self.content
        self.content = content
        let newShape = rebuildNodes()
        isSyncing = true
        isShowing = true
        defer {
            isSyncing = false
            isShowing = false
        }
        let oldHeights = headerHeights
        headerHeights = sections.map { max($0.headerHeight(for: content), 1) }
        if newShape != shape {
            shape = newShape
            cancelRenames(in: IndexSet(integersIn: 0..<outlineView.numberOfRows))
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
            if !changed.isEmpty {
                cancelRenames(in: changed)
                outlineView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
            // A header whose height changed with the content gets its new height without rebuilding the rows.
            let resized = IndexSet(
                headerHeights.indices.filter { oldHeights.indices.contains($0) && oldHeights[$0] != headerHeights[$0] }
                    .map { outlineView.row(forItem: roots[$0]) }.filter { $0 >= 0 })
            if !resized.isEmpty { outlineView.noteHeightOfRows(withIndexesChanged: resized) }
        }
        syncSelection()
        refreshRows()
        for (index, view) in headerViews {
            sections[index].updateHeaderView(view, content: content, context: delegate)
        }
        for accessory in accessories { accessory.update(content: content, context: delegate) }
    }

    /// Swaps the outline's content with a slide, as swiping between Spaces does: the content on screen now slides
    /// out towards `direction` while the content `change` shows (by calling `show(_:)`) comes in from the other side.
    /// Without a window, or with Reduce Motion on, `change` runs without the slide.
    func slideOutline(_ direction: SidebarSlideDirection, duration: TimeInterval = 0.25, change: () -> Void) {
        let bounds = scrollView.bounds
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, !bounds.isEmpty,
            let picture = scrollView.bitmapImageRepForCachingDisplay(in: bounds)
        else {
            change()
            return
        }
        scrollView.cacheDisplay(in: bounds, to: picture)
        if slidesRunning == 0 {
            clipsBeforeSlides = clipsToBounds
            scrollLayerBeforeSlides = scrollView.wantsLayer
        }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(picture)
        let snapshot = SidebarSlideSnapshot(frame: scrollView.frame)
        snapshot.image = image
        snapshot.imageScaling = .scaleNone
        snapshot.wantsLayer = true
        addSubview(snapshot, positioned: .above, relativeTo: scrollView)
        change()
        layoutSubtreeIfNeeded()
        scrollView.wantsLayer = true
        guard let oldLayer = snapshot.layer, let newLayer = scrollView.layer else {
            snapshot.removeFromSuperview()
            if slidesRunning == 0 { scrollView.wantsLayer = scrollLayerBeforeSlides }
            return
        }
        // Neither side may draw over the page next to the sidebar while it slides; clipping and the scroll view's layer
        // go back as they were once the last slide running ends.
        slidesRunning += 1
        clipsToBounds = true
        let offset = bounds.width * (direction == .left ? -1 : 1)
        func slide(_ layer: CALayer, from: CGFloat, to: CGFloat) {
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "bow.slide")
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            snapshot.removeFromSuperview()
            guard let self else { return }
            self.slidesRunning -= 1
            if self.slidesRunning == 0 {
                self.clipsToBounds = self.clipsBeforeSlides
                self.scrollView.wantsLayer = self.scrollLayerBeforeSlides
            }
        }
        // The snapshot ends off screen, so it stays there (and not back at its start) until it is removed.
        oldLayer.transform = CATransform3DMakeTranslation(offset, 0, 0)
        slide(oldLayer, from: 0, to: offset)
        slide(newLayer, from: -offset, to: 0)
        CATransaction.commit()
    }

    /// Makes the name of folder or split `item` editable in its row (`SidebarActionContext.beginRename`), scrolling
    /// the row into view; the new name is saved through the delegate. Returns false when `item` has no group row on
    /// screen or the row cannot take the keyboard focus.
    @discardableResult
    func beginRename(_ item: SidebarItemID) -> Bool {
        guard let row = row(for: item) else { return false }
        outlineView.scrollRowToVisible(row)
        guard let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarGroupRow else {
            return false
        }
        return view.beginRename()
    }

    /// Ends without saving any folder rename running in `rows`, which are about to be reloaded.
    private func cancelRenames(in rows: IndexSet) {
        for row in rows {
            (outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarGroupRow)?.cancelRename()
        }
    }

    /// Hands the scroll view's sideways swipes to `swipeHandler`, or leaves them all to the outline without one.
    private func connectSwipes() {
        guard swipeHandler != nil else {
            scrollView.onSwipe = nil
            return
        }
        scrollView.onSwipe = { [weak self] swipe in
            guard let self, let handler = self.swipeHandler, let context = self.delegate else { return }
            handler.sidebarSwipe(swipe, context: context)
        }
    }

    /// Runs `body`, which updates a header or accessory outside `show(_:)`, so a show it causes waits for the next
    /// run loop turn rather than reloading the outline from inside the outline's own call.
    private func updatingSlots(_ body: () -> Void) {
        let wasUpdating = isUpdatingSlots
        isUpdatingSlots = true
        defer { isUpdatingSlots = wasUpdating }
        body()
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
            // The outline's child index equals the graph's: integrity forbids containers and duplicate children.
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

    /// Updates each tab row on screen for the content: which shows itself active (its close button), after the
    /// highlight moved, and its accessory.
    private func refreshRows() {
        for row in 0..<outlineView.numberOfRows {
            guard let view = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarRow,
                let id = (outlineView.item(atRow: row) as? SidebarNode)?.itemID
            else { continue }
            view.isActive = id == content.activeItem
            updateAccessory(of: view, for: id)
        }
    }

    /// Gives tab `item`'s row the view of the first row accessory provider that has one, or none.
    private func updateAccessory(of view: TabSidebarRow, for item: SidebarItemID) {
        guard !SidebarRowAccessories.all.isEmpty else { return }
        let current = view.accessoryView
        view.accessoryView =
            SidebarRowAccessories.all.lazy.compactMap {
                $0.accessoryView(for: item, reusing: current, content: self.content, context: self.delegate)
            }.first
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

    @objc private func outlineDoubleClicked(_ sender: Any?) {
        doubleClickRow(outlineView.clickedRow)
    }

    /// What a double click on row `row` does beyond its two clicks: on a folder or split row it starts renaming it in
    /// place (`SidebarActionContext.beginRename`). Elsewhere it does nothing more.
    func doubleClickRow(_ row: Int) {
        guard row >= 0, let id = (outlineView.item(atRow: row) as? SidebarNode)?.itemID,
            let item = content.graph[id], !item.data.isTab, !item.data.isContainer
        else { return }
        delegate?.beginRename(id)
    }

    /// A drop the outline resolved: what it makes, and the row and child index the outline shows its gap at (-1, on
    /// the row itself, for a closed folder, whose children have no rows to put a gap between).
    struct ProposedDrop {
        let drop: SidebarDrop
        let node: SidebarNode
        let childIndex: Int
    }

    /// Where a drop of `item` the outline proposes on `node` (nil between sections) at `childIndex` (-1 on the row
    /// itself) lands, nil when no rule allows it there: a container, folder or split and a position in it. A drop on a
    /// tab goes above it, a drop on the divider to the top of the section after it, a drop on a folder or split to
    /// its end, and a drop between sections to the end of the section above or, when that is refused (Favorites),
    /// the top of the one below. Both the outline's drag and the e2e drag resolve drops here.
    func proposeDrop(of item: SidebarItemID, on node: SidebarNode?, childIndex: Int) -> ProposedDrop? {
        guard
            let drop = dropCandidates(on: node, index: childIndex).lazy
                .map({ SidebarDrop(item: item, parent: $0.parent, index: $0.index) })
                .first(where: { SidebarDropValidators.allows($0, in: self.content.graph) }),
            let target = outlineNode(for: drop.parent)
        else { return nil }
        let isClosed = target.itemID != nil && !outlineView.isItemExpanded(target)
        return ProposedDrop(drop: drop, node: target, childIndex: isClosed ? NSOutlineViewDropOnItemIndex : drop.index)
    }

    /// Makes the drop of `item` the outline accepts on `node` at `childIndex`, resolved as `proposeDrop` does.
    /// Returns whether it went through; a drop no rule allows changes nothing.
    func acceptDrop(of item: SidebarItemID, on node: SidebarNode?, childIndex: Int) -> Bool {
        guard let delegate, let proposal = proposeDrop(of: item, on: node, childIndex: childIndex) else { return false }
        return proposal.drop.perform(in: delegate)
    }

    /// Drags `item` onto row `row` (nil for between sections) at `childIndex` (-1 on the row itself), as the outline
    /// does: it proposes the drop, moves the gap to where it resolves and accepts it there. Returns whether it moved.
    @discardableResult
    func dragItem(_ item: SidebarItemID, onRow row: Int?, childIndex: Int) -> Bool {
        var node: SidebarNode?
        if let row {
            guard row >= 0, row < outlineView.numberOfRows, let found = outlineView.item(atRow: row) as? SidebarNode
            else { return false }
            node = found
        }
        return drag(item, on: node, childIndex: childIndex)
    }

    /// Drags `item` into `parent` at `index` (counted before it leaves its place), as dropping its row in that gap
    /// does, also when `parent`'s rows are hidden in a closed folder. Returns whether it moved.
    @discardableResult
    func dragItem(_ item: SidebarItemID, into parent: SidebarItemID, at index: Int) -> Bool {
        guard let node = outlineNode(for: parent) else { return false }
        return drag(item, on: node, childIndex: index)
    }

    private func drag(_ item: SidebarItemID, on node: SidebarNode?, childIndex: Int) -> Bool {
        guard let proposal = proposeDrop(of: item, on: node, childIndex: childIndex) else { return false }
        return acceptDrop(of: item, on: proposal.node, childIndex: proposal.childIndex)
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
        return headerHeights.indices.contains(index) ? headerHeights[index] : max(sections[index].headerHeight, 1)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.key {
        case .section(let index):
            if let view = headerViews[index] { return view }
            guard !askedHeaders.contains(index) else { return nil }
            askedHeaders.insert(index)
            guard let view = sections[index].makeHeaderView() else { return nil }
            headerViews[index] = view
            // During `show(_:)` every header is updated once, at its end.
            if !isShowing {
                updatingSlots { sections[index].updateHeaderView(view, content: content, context: delegate) }
            }
            return view
        case .item(let id):
            guard let item = content.graph[id] else { return nil }
            guard let saved = item.tab else {
                let view =
                    outlineView.makeView(withIdentifier: SidebarGroupRow.identifier, owner: nil) as? SidebarGroupRow
                    ?? SidebarGroupRow()
                view.show(item)
                view.onRename = { [weak self] name in
                    // Saved on the next run loop turn: the change reloads this row, which is still ending its edit.
                    DispatchQueue.main.async {
                        self?.delegate?.changeSidebar { try $0.apply([.rename(id, title: name)]) }
                    }
                }
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
            // During `show(_:)` its `refreshRows()` gives every row on screen its accessory once, at the end.
            if !isShowing { updatingSlots { updateAccessory(of: view, for: id) } }
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
        guard !isSyncing, !isDragging, let node = notification.userInfo?["NSObject"] as? SidebarNode,
            let id = node.itemID,
            case .folder(let folder)? = content.graph[id]?.data, folder.isExpanded != expanded
        else { return }
        delegate?.changeSidebar { try $0.apply([.setFolderExpanded(id, expanded)]) }
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
        forItems draggedItems: [Any]
    ) {
        isDragging = true
    }

    func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDragging = false
        // Closes again any folder the drag opened on hover and the drop did not save open.
        isSyncing = true
        defer { isSyncing = false }
        syncExpansion(roots)
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
            let proposal = proposeDrop(of: id, on: item as? SidebarNode, childIndex: index)
        else { return [] }
        outlineView.setDropItem(proposal.node, dropChildIndex: proposal.childIndex)
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let id = draggedItem(info) else { return false }
        return acceptDrop(of: id, on: item as? SidebarNode, childIndex: index)
    }

    private func draggedItem(_ info: any NSDraggingInfo) -> SidebarItemID? {
        info.draggingPasteboard.string(forType: Self.dragType).map { SidebarItemID($0) }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in menuItems(forRow: outlineView.clickedRow) { menu.addItem(item) }
    }

    /// The context menu of row `row`: its item's kind's items, or for a section header its zone's items for the
    /// container it lists (none for the divider). Empty outside the rows.
    func menuItems(forRow row: Int) -> [NSMenuItem] {
        guard row >= 0, let node = outlineView.item(atRow: row) as? SidebarNode, let delegate else { return [] }
        switch node.key {
        case .item(let id):
            return SidebarMenus.menu(for: id, context: delegate)
        case .section(let index):
            guard let zone = sections[index].zone, let container = container(ofSection: index) else { return [] }
            return SidebarMenus.menu(for: container, kind: .section(zone), context: delegate)
        }
    }
}
