import AppKit

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
}
