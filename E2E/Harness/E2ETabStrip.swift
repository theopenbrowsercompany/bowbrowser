import Foundation

/// One tab pill of the top tabs layout's strip, as a test reads it. Frames are in window coordinates from the window's
/// top and leading edges, in points.
struct E2EStripPill: Equatable, CustomStringConvertible {
    var title: String
    var frame: E2ETopFrame
    var isActive: Bool
    /// The pill's fill ("#RRGGBB"), nil when it has none.
    var fill: String?
    var radius: Double
    var titleSize: Double
    /// Whether the title is the bold face (700) the active pill has.
    var titleBold: Bool
    var titleOneLine: Bool
    /// The title's leading edge and the icon's frame, from the pill's own leading edge.
    var titleX: Double
    var iconX: Double
    var iconSize: Double
    var hasFavicon: Bool
    /// The soft shadow: blur radius, offset (y, down is negative) and the color's opacity; all 0 with none.
    var shadowBlur: Double
    var shadowOffsetY: Double
    var shadowOpacity: Double
    var closeShown: Bool

    var description: String {
        "\"\(title)\" \(frame) active=\(isActive) fill=\(fill ?? "nil") radius=\(Int(radius)) "
            + "title=\(titleSize)\(titleBold ? "b" : "") icon=\(Int(iconX)),\(Int(iconSize)) "
            + "shadow=\(shadowBlur)/\(shadowOffsetY)/\(shadowOpacity) close=\(closeShown)"
    }
}

/// The tab strip row now.
struct E2ETabStripState: Equatable, CustomStringConvertible {
    var pills: [E2EStripPill]
    var plus: E2ETopFrame
    var plusTint: String?
    /// The window buttons' trailing edge (the zoom button's) and the strip's own width.
    var buttonsTrailingEdge: Double
    var stripWidth: Double
    /// The room the pills have, and how far they are scrolled.
    var viewportWidth: Double
    var scrollOffset: Double

    var activeIndex: Int? { pills.firstIndex { $0.isActive } }
    var titles: [String] { pills.map(\.title) }

    var description: String {
        "pills=[\(pills.map(\.description).joined(separator: "; "))] plus=\(plus) tint=\(plusTint ?? "nil") "
            + "buttons=\(Int(buttonsTrailingEdge)) strip=\(Int(stripWidth)) viewport=\(Int(viewportWidth)) "
            + "scroll=\(Int(scrollOffset))"
    }
}

@MainActor
protocol E2ETabStripApp: E2ETopTabsApp {
    /// The strip's pills and + button now.
    func tabStrip(of page: any E2EPage) throws -> E2ETabStripState
    /// Presses pill `index` the way a click on it does (its mouseDown handler). Throws when there is no such pill.
    func pressTopPill(_ index: Int, in page: any E2EPage) throws
    /// Moves the pointer onto or off pill `index` as its tracking area does.
    func hoverTopPill(_ index: Int, _ hovered: Bool, in page: any E2EPage) throws
    /// Clicks pill `index`'s close button. Throws unless the button shows.
    func clickTopPillClose(_ index: Int, in page: any E2EPage) throws
    /// Clicks the + button.
    func clickTopPlus(in page: any E2EPage) throws
}
