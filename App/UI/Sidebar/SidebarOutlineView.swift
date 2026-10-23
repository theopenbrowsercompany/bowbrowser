import AppKit
import BowCore

/// The sidebar's outline, placing its rows' views as the reference design does:
/// - a section header (level 0: the Favorites grid, the Space name, the divider) spans the whole row, so it lays out
///   against the sidebar's own padding rather than after the outline's disclosure gutter;
/// - an item directly in a section (level 1) stays where the outline puts it;
/// - an item inside a folder steps in `childIndent` points per level, so its icon sits under its folder's title.
///
/// The outline steps each level in by `indentationPerLevel`, disclosure triangle included; the extra step for rows
/// inside folders moves a nested folder's triangle along with its row.
@MainActor
final class SidebarOutlineView: NSOutlineView {
    /// How far a row inside a folder steps in from its folder's row.
    static let childIndent: CGFloat = 22

    /// The extra step for a row at `level`, beyond the outline's own: none for rows directly in a section.
    private func extraIndent(atLevel level: Int) -> CGFloat {
        CGFloat(max(level - 1, 0)) * (Self.childIndent - indentationPerLevel)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        let level = level(forRow: row)
        if level == 0 {
            let whole = rect(ofRow: row)
            frame.origin.x = whole.minX
            frame.size.width = whole.width
            return frame
        }
        let extra = extraIndent(atLevel: level)
        frame.origin.x += extra
        frame.size.width = max(frame.width - extra, 0)
        return frame
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        frame.origin.x += extraIndent(atLevel: level(forRow: row))
        return frame
    }

    // MARK: Drop level

    /// Retargets a drop the outline proposes in a gap (`childIndex` 0 or more in `item`, nil for the top level) to
    /// the level the pointer at `pointerX` picks with the sidebar's own indent (`SidebarDropLevel`), rather than the
    /// outline's, which steps `indentationPerLevel` points per level while folder rows step `childIndent`. A drop on
    /// a row (`NSOutlineViewDropOnItemIndex`) and a gap the outline has no row above keep the outline's proposal.
    func retargetedDrop(proposedItem item: Any?, childIndex: Int, pointerX: CGFloat) -> (item: Any?, childIndex: Int) {
        guard childIndex >= 0, let above = rowAboveGap(in: item, at: childIndex),
            let target = retargetedDrop(gapBelowRow: above, pointerX: pointerX)
        else { return (item, childIndex) }
        return target
    }

    /// Where a drop in the gap below row `row` lands with the pointer at `pointerX`: a parent and a child index in it.
    /// Nil when `row` is not an item's row: below a section's header row the gap has one place only, which the
    /// outline's proposal already names.
    func retargetedDrop(gapBelowRow row: Int, pointerX: CGFloat) -> (item: Any?, childIndex: Int)? {
        guard row >= 0, row < numberOfRows, let above = item(atRow: row), level(forRow: row) > 0 else { return nil }
        let aboveLevel = level(forRow: row)
        let below = row + 1 < numberOfRows ? level(forRow: row + 1) : nil
        let opens = isExpandable(above) && isItemExpanded(above)
        let levels = SidebarDropLevel.levels(above: aboveLevel, aboveOpensChildren: opens, below: below)
        let level = SidebarDropLevel.level(
            pointerX: Double(pointerX), firstLevelX: Double(firstLevelX(measuredOn: row)),
            step: Double(Self.childIndent),
            in: levels)
        if level > aboveLevel { return (above, 0) }
        // The row above's ancestor at that level; the drop goes right after it in its parent.
        var ancestor: Any = above
        while self.level(forItem: ancestor) > level, let up = parent(forItem: ancestor) { ancestor = up }
        return (parent(forItem: ancestor), childIndex(forItem: ancestor) + 1)
    }

    /// Where rows at level 1 start their cell, measured on item row `row`.
    private func firstLevelX(measuredOn row: Int) -> CGFloat {
        frameOfCell(atColumn: 0, row: row).minX - CGFloat(level(forRow: row) - 1) * Self.childIndent
    }

    /// The row just above the gap at child `index` of `item` (nil for the top level): the item itself for its first
    /// slot, else the last row shown inside the child before the gap. Nil for the very top of the outline.
    private func rowAboveGap(in item: Any?, at index: Int) -> Int? {
        if index == 0 {
            let row = row(forItem: item)
            return row >= 0 ? row : nil
        }
        guard index <= numberOfChildren(ofItem: item), let previous = child(index - 1, ofItem: item) else { return nil }
        let start = row(forItem: previous)
        guard start >= 0 else { return nil }
        let level = level(forRow: start)
        var last = start
        while last + 1 < numberOfRows, self.level(forRow: last + 1) > level { last += 1 }
        return last
    }

    // MARK: Hover after scrolling

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if let clip = superview as? NSClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clip)
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged(_:)), name: NSView.boundsDidChangeNotification, object: clip)
    }

    /// A scroll moves rows under a still pointer without telling their tracking areas, so each row on screen checks
    /// again whether the pointer is over it.
    @objc private func clipBoundsChanged(_ notification: Notification) {
        refreshHover()
    }

    /// Has every row on screen light or clear its hover for where the pointer is now.
    func refreshHover() {
        enumerateAvailableRowViews { rowView, _ in
            (rowView as? SidebarRowView)?.refreshHover()
            for case let cell as TabSidebarRow in rowView.subviews { cell.refreshHover() }
        }
    }
}
