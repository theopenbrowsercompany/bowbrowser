import Foundation

/// Which half of a tab row a drop released on the row itself falls in: the upper half lands above the row, the lower
/// half below it, as in Arc and standard outline views.
public enum SidebarDropHalf {
    /// Whether a pointer `offset` points down a row `height` points tall is in its lower half. The middle counts as
    /// the upper half, and a row without a usable height or a pointer outside it has no lower half beyond its edges.
    public static func isLower(offset: Double, height: Double) -> Bool {
        guard height > 0, offset.isFinite, height.isFinite else { return false }
        return offset > height / 2
    }
}
