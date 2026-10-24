import Foundation

/// The sidebar footer's part of `E2EDesignLook`: the Space dots, their colors and menu, and the buttons around them.
/// Read by E2E/Harness/E2EAppAdapter+DesignFooter.swift.
struct E2EDesignFooterLook {
    /// The active Space's dot: its size, its ring's width and color, and the gap between them.
    var spaceDotSize: Double
    var spaceRingWidth: Double
    var spaceRingGap: Double
    var spaceRingColor: String?
    /// How far the Space dots' middle is from the middle of the gap between the archive button's trailing edge and
    /// the "+" button's leading edge (0 when centred), and whether the downloads and archive buttons sit left of the
    /// dots and the "+" right of them.
    var dotsOffset: Double
    var order: Bool
    /// Each Space dot's color in order, `#RRGGBB` (nil for a Space showing an emoji or symbol), and the titles of the
    /// active dot's context menu ("<submenu>/<item>" after a submenu, "-" for a separator).
    var dotColors: [String?]
    var dotMenu: [String]
}
