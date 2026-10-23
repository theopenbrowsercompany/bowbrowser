import Foundation

/// The top tabs layout's tab strip: how wide each tab pill is, where it sits and how the strip scrolls when the pills
/// do not fit. The measurements are the maintainer's top tabs mockup, in points.
///
/// Pills are 190 wide while they fit, and shrink evenly together (as Chrome's tabs do) down to `minPillWidth`; past
/// that the pills keep the minimum and the strip scrolls, keeping the shown tab in view.
public enum TabStripLayout {
    /// A pill's width while there is room, and its height and corner radius.
    public static let pillWidth: Double = 190
    public static let pillHeight: Double = 32
    public static let pillRadius: Double = 10
    /// The gap between pills, and between the last pill and the + button.
    public static let gap: Double = 8
    /// A pill's padding on each side inside, and the favicon's size.
    public static let pillPadding: Double = 12
    public static let faviconSize: Double = 15
    /// The title's size in points.
    public static let titleSize: Double = 13
    /// The + button's frame side, and the size of its plus symbol.
    public static let plusButtonSize: Double = 32
    public static let plusSymbolSize: Double = 17
    /// The gap between the window buttons and the first pill.
    public static let buttonsGap: Double = 10
    /// The narrowest a pill shrinks to: the favicon, a few letters of the title and room for the close button.
    public static let minPillWidth: Double = 96

    /// The strip's leading inset: after the window buttons, which end at `buttonsTrailingEdge`.
    public static func leadingInset(buttonsTrailingEdge: Double) -> Double {
        buttonsTrailingEdge + buttonsGap
    }

    /// The width of each of `count` pills in `available` points for the pills and the gaps between them: the full
    /// width when they fit, else an even share of what is left, never below the minimum.
    public static func width(count: Int, available: Double) -> Double {
        guard count > 0 else { return pillWidth }
        let gaps = gap * Double(count - 1)
        let share = (available - gaps) / Double(count)
        return min(pillWidth, max(minPillWidth, share))
    }

    /// The width of all `count` pills of width `width` with the gaps between.
    public static func contentWidth(count: Int, pillWidth width: Double) -> Double {
        guard count > 0 else { return 0 }
        return Double(count) * width + gap * Double(count - 1)
    }

    /// The leading edge of pill `index` inside the pills' content.
    public static func originX(of index: Int, pillWidth width: Double) -> Double {
        Double(index) * (width + gap)
    }

    /// The scroll offset that shows pill `index` fully in a viewport `viewport` wide, moving as little as possible from
    /// `current`; always within the content.
    public static func scrollOffset(
        revealing index: Int, count: Int, pillWidth width: Double, viewport: Double, current: Double
    ) -> Double {
        let maximum = max(0, contentWidth(count: count, pillWidth: width) - viewport)
        guard count > 0, index >= 0, index < count else { return min(max(current, 0), maximum) }
        let start = originX(of: index, pillWidth: width)
        var offset = current
        if start < offset { offset = start }
        if start + width > offset + viewport { offset = start + width - viewport }
        return min(max(offset, 0), maximum)
    }
}
