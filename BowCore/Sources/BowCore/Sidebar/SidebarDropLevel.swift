import Foundation

/// The level a drop between two sidebar rows lands on, from the pointer's x and the sidebar's own indent.
///
/// Levels count as the outline does: 0 for a section's header row, 1 for an item directly in a section, and one more
/// for each folder or split around it. A gap between two rows can mean several places: below a folder's last child it
/// is the folder's end, or the place after the folder in its own parent, and so on up to the level of the row below.
/// The pointer's x picks one, stepping `step` points per level as the sidebar draws its rows, so dropping at a
/// folder's own x lands beside the folder and dropping at its children's x lands among them.
public enum SidebarDropLevel {
    /// The levels a drop in the gap below a row at level `above` may land on: down to the level of the row below
    /// (`below`, nil at the end of the list) but never above `lowest`, and up to `above`, or one deeper when the row
    /// above is an open folder or split, whose first child slot the gap also is.
    public static func levels(above: Int, aboveOpensChildren: Bool, below: Int?, lowest: Int = 1) -> ClosedRange<Int> {
        let deepest = max(aboveOpensChildren ? above + 1 : above, lowest)
        let shallowest = min(max(below ?? lowest, lowest), deepest)
        return shallowest...deepest
    }

    /// The level in `levels` a drop with the pointer at `pointerX` lands on, where rows at level 1 start at
    /// `firstLevelX` and each level steps in `step` points: the deepest level whose rows start at or left of the
    /// pointer, kept within `levels`.
    public static func level(pointerX: Double, firstLevelX: Double, step: Double, in levels: ClosedRange<Int>) -> Int {
        guard step > 0, pointerX.isFinite, firstLevelX.isFinite else { return levels.upperBound }
        // Clamped as a Double first, so a pointer far outside the list never overflows the conversion.
        let level = ((pointerX - firstLevelX) / step).rounded(.down) + 1
        return Int(min(max(level, Double(levels.lowerBound)), Double(levels.upperBound)))
    }
}
