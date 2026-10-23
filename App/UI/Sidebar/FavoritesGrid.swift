import AppKit
import BowCore

/// The geometry of the Favorites grid: rows of `columns` square-cornered tiles, filled left to right and top to
/// bottom, with the grid exactly as tall as its rows.
enum FavoritesGridLayout {
    static let columns = 4
    static let tileHeight: CGFloat = 40
    static let spacing: CGFloat = 6
    static let insets = NSEdgeInsets(top: 4, left: 10, bottom: 8, right: 10)
    /// The height of a grid without Favorites: a thin strip that still takes a tab dropped on it.
    static let emptyHeight: CGFloat = 12

    static func rows(for count: Int) -> Int { (max(count, 0) + columns - 1) / columns }

    /// The grid's height for `count` Favorites.
    static func height(for count: Int) -> CGFloat {
        guard count > 0 else { return emptyHeight }
        let rows = CGFloat(rows(for: count))
        return insets.top + rows * tileHeight + (rows - 1) * spacing + insets.bottom
    }

    static func tileWidth(in width: CGFloat) -> CGFloat {
        max((width - insets.left - insets.right - CGFloat(columns - 1) * spacing) / CGFloat(columns), 1)
    }

    /// The frame of tile `index` in a grid `width` wide, in flipped coordinates (top left origin).
    static func frame(ofTile index: Int, width: CGFloat) -> NSRect {
        let tileWidth = tileWidth(in: width)
        let row = CGFloat(index / columns)
        let column = CGFloat(index % columns)
        return NSRect(
            x: insets.left + column * (tileWidth + spacing), y: insets.top + row * (tileHeight + spacing),
            width: tileWidth, height: tileHeight)
    }

    /// The gap a drop at `point` (flipped coordinates) lands in among `count` tiles: before the tile under it, or after
    /// it past the tile's middle, and after the last tile below or beside the last one.
    static func gap(at point: NSPoint, count: Int, width: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let tileWidth = tileWidth(in: width)
        let row = min(max(Int((point.y - insets.top) / (tileHeight + spacing)), 0), rows(for: count) - 1)
        let column = min(max(Int((point.x - insets.left) / (tileWidth + spacing)), 0), columns - 1)
        let index = row * columns + column
        guard index < count else { return count }
        return point.x > frame(ofTile: index, width: width).midX ? index + 1 : index
    }
}

/// The Favorites of the profile the Space on screen uses, as a grid of icons at the top of the sidebar (Arc's
/// Favorites). Each tile shows its site's icon, or the first letter of its title when there is none. A click opens
/// the Favorite or shows the tab it opened; dragging a tab onto the grid makes it a Favorite at the gap under the
/// pointer, dragging a tile reorders it or moves it out to the pinned or today zone, and right-clicking a tile shows
/// the Favorite's menu (`SidebarMenus`).
@MainActor
final class FavoritesGridView: NSView {
    private weak var context: (any SidebarActionContext)?
    private(set) var tiles: [FavoriteTileView] = []
    /// The tab a click on each Favorite opened, so the next click shows that tab rather than opening another.
    private var openedTabs: [SidebarItemID: SidebarItemID] = [:]
    /// The site icon a tab showed when it was dragged in, kept while the Favorite has no loaded page of its own.
    private var icons: [SidebarItemID: NSImage] = [:]
    private let dropIndicator = NSView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([SidebarView.dragType])
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1
        dropIndicator.isHidden = true
        addSubview(dropIndicator)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Favorites")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the Favorites `content` lists for the Space on screen, keeping each tile across updates.
    func update(content: SidebarContent, context: (any SidebarActionContext)?) {
        self.context = context
        let graph = content.graph
        openedTabs = openedTabs.filter { graph[$0.key] != nil && graph[$0.value]?.data.isTab == true }
        let ids = graph.activeFavoriteIDs
        icons = icons.filter { ids.contains($0.key) }
        let existing = Dictionary(tiles.map { ($0.item, $0) }, uniquingKeysWith: { first, _ in first })
        let next = ids.map { id in existing[id] ?? makeTile(for: id) }
        for tile in tiles where !next.contains(where: { $0 === tile }) { tile.removeFromSuperview() }
        for tile in next where tile.superview == nil { addSubview(tile, positioned: .below, relativeTo: dropIndicator) }
        tiles = next
        for tile in tiles {
            guard let item = graph[tile.item], let saved = item.tab else { continue }
            if let icon = context?.favicon(for: tile.item) { icons[tile.item] = icon }
            let opened = openedTabs[tile.item]
            tile.show(
                title: Self.title(of: item, saved: saved), icon: icons[tile.item],
                isActive: content.activeItem != nil && (opened == content.activeItem || tile.item == content.activeItem)
            )
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, tile) in tiles.enumerated() {
            tile.frame = FavoritesGridLayout.frame(ofTile: index, width: bounds.width)
        }
    }

    private func makeTile(for id: SidebarItemID) -> FavoriteTileView {
        let tile = FavoriteTileView(item: id)
        tile.onClick = { [weak self] in self?.click(id) }
        tile.menuItems = { [weak self] in self?.menuItems(for: id) ?? [] }
        return tile
    }

    /// The name a Favorite shows: its own name, else its saved page's title, else its site's host.
    static func title(of item: SidebarItem, saved: SidebarTab) -> String {
        if let custom = item.title, !custom.isEmpty { return custom }
        if !saved.savedTitle.isEmpty { return saved.savedTitle }
        return saved.savedPageURL?.host() ?? saved.savedURL
    }

    // MARK: Actions

    /// What a click on Favorite `item` does: shows its own loaded page or the tab an earlier click opened when that
    /// tab is still in the Space on screen; otherwise opens it (`SidebarActionContext.open(favorite:)`) and remembers
    /// the tab it opened. Returns whether a tab was shown or opened.
    @discardableResult
    func click(_ item: SidebarItemID) -> Bool {
        guard let context else { return false }
        let graph = context.graph
        if context.livePage(of: item) != nil {
            context.select(item)
            return true
        }
        if let tab = openedTabs[item], graph[tab]?.data.isTab == true, let space = graph.activeSpaceID,
            graph.spaceID(containing: tab) == space
        {
            context.select(tab)
            return true
        }
        guard context.open(favorite: item) else { return false }
        openedTabs[item] = context.graph.activeSpace?.lastSelectedTabID
        return true
    }

    /// Drops sidebar item `item` into the grid at gap `index` (counted before it leaves its place), as dropping it
    /// there does: a tab becomes a Favorite keeping its saved page, and a Favorite moves within the grid. Returns
    /// whether the drop went through; one no rule allows changes nothing.
    @discardableResult
    func drop(_ item: SidebarItemID, at index: Int) -> Bool {
        guard let context, let drop = proposedDrop(of: item, at: index, in: context.graph) else { return false }
        let graph = context.graph
        let storeIndex = drop.storeIndex(in: graph)
        if graph[item]?.parentID == drop.parent, graph[drop.parent]?.childrenIDs.firstIndex(of: item) == storeIndex {
            return true
        }
        if let icon = context.favicon(for: item) { icons[item] = icon }
        let profile = graph.activeSpace?.profileID
        return context.changeSidebar { try $0.moveToFavorites(item, profile: profile, at: storeIndex) }
    }

    /// The context menu of Favorite `item`.
    func menuItems(for item: SidebarItemID) -> [NSMenuItem] {
        guard let context else { return [] }
        return SidebarMenus.menu(for: item, context: context)
    }

    private func proposedDrop(of item: SidebarItemID, at index: Int, in graph: SidebarGraph) -> SidebarDrop? {
        guard let space = graph.activeSpace, let container = graph.favoritesContainerID(for: space.profileID) else {
            return nil
        }
        let drop = SidebarDrop(item: item, parent: container, index: index)
        return SidebarDropValidators.allows(drop, in: graph) ? drop : nil
    }

    // MARK: Dragging onto the grid

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let (item, index) = dropTarget(sender), let context,
            proposedDrop(of: item, at: index, in: context.graph) != nil
        else {
            dropIndicator.isHidden = true
            return []
        }
        showIndicator(at: index)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropIndicator.isHidden = true
        guard let (item, index) = dropTarget(sender) else { return false }
        return drop(item, at: index)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        dropIndicator.isHidden = true
    }

    /// The item a drag carries and the gap under the pointer, for drags that start in this window's sidebar.
    private func dropTarget(_ info: any NSDraggingInfo) -> (SidebarItemID, Int)? {
        guard let sidebar = enclosingSidebar, (info.draggingSource as? NSView)?.isDescendant(of: sidebar) == true,
            let raw = info.draggingPasteboard.string(forType: SidebarView.dragType)
        else { return nil }
        return (SidebarItemID(raw), gap(at: convert(info.draggingLocation, from: nil)))
    }

    /// The gap a drop at `point` (in this view) lands in.
    func gap(at point: NSPoint) -> Int {
        FavoritesGridLayout.gap(at: point, count: tiles.count, width: bounds.width)
    }

    private var enclosingSidebar: SidebarView? {
        var view = superview
        while let current = view {
            if let sidebar = current as? SidebarView { return sidebar }
            view = current.superview
        }
        return nil
    }

    /// Shows the drop line in gap `index`: before its tile, or after the last tile.
    private func showIndicator(at index: Int) {
        let width = bounds.width
        let frame: NSRect
        if tiles.isEmpty {
            frame = NSRect(x: FavoritesGridLayout.insets.left, y: bounds.midY - 1, width: width - 20, height: 2)
        } else {
            let tile = FavoritesGridLayout.frame(ofTile: min(index, tiles.count - 1), width: width)
            let x = index < tiles.count ? tile.minX - FavoritesGridLayout.spacing / 2 : tile.maxX + 1
            frame = NSRect(x: x - 1, y: tile.minY, width: 2, height: tile.height)
        }
        dropIndicator.frame = frame
        dropIndicator.isHidden = false
    }
}

/// One Favorite in the grid: its site icon (or a letter tile) on a rounded tile, highlighted while its tab is shown.
/// A click runs `onClick`; dragging it carries the Favorite's ID as a sidebar drag, so it can land back in the grid
/// or in the outline.
@MainActor
final class FavoriteTileView: NSView, NSDraggingSource {
    let item: SidebarItemID
    var onClick: (() -> Void)?
    var menuItems: (() -> [NSMenuItem])?
    let iconView = NSImageView()
    let letterField = NSTextField(labelWithString: "")
    private(set) var title = ""
    private(set) var isActive = false
    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    /// True while the tile shows a site icon rather than the letter tile.
    var hasIcon: Bool { !iconView.isHidden }

    init(item: SidebarItemID) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        iconView.imageScaling = .scaleProportionallyUpOrDown
        letterField.alignment = .center
        letterField.font = .systemFont(ofSize: 13, weight: .semibold)
        letterField.textColor = .white
        letterField.wantsLayer = true
        letterField.layer?.cornerRadius = 5
        for view in [iconView, letterField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            letterField.centerXAnchor.constraint(equalTo: centerXAnchor),
            letterField.centerYAnchor.constraint(equalTo: centerYAnchor),
            letterField.widthAnchor.constraint(equalToConstant: 20),
            letterField.heightAnchor.constraint(equalToConstant: 20),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(title: String, icon: NSImage?, isActive: Bool) {
        self.title = title
        self.isActive = isActive
        iconView.image = icon
        iconView.isHidden = icon == nil
        letterField.isHidden = icon != nil
        letterField.stringValue = title.first.map { String($0).uppercased() } ?? "?"
        letterField.layer?.backgroundColor = Self.letterColor(for: title).cgColor
        toolTip = title
        setAccessibilityLabel(title)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let fill = isActive ? NSColor.labelColor.withAlphaComponent(0.18) : NSColor.labelColor.withAlphaComponent(0.07)
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fill.cgColor }
    }

    /// A steady color per title, so a letter tile keeps its color across launches.
    private static func letterColor(for title: String) -> NSColor {
        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemGreen]
        let sum = title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[sum % colors.count]
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownPoint else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        isDragging = true
        let writer = NSPasteboardItem()
        writer.setString(item.rawValue, forType: SidebarView.dragType)
        let dragItem = NSDraggingItem(pasteboardWriter: writer)
        let image = bitmapImageRepForCachingDisplay(in: bounds).map { rep -> NSImage in
            cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            return image
        }
        dragItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard mouseDownPoint != nil, !isDragging, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = menuItems?() ?? []
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        return menu
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownPoint = nil
    }
}
