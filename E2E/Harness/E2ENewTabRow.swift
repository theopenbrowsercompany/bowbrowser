import Foundation

/// How the sidebar's New Tab row looks and sits, as drawn.
struct E2ENewTabRowState: Equatable, CustomStringConvertible {
    var title: String
    /// True when the row is the last row of the outline.
    var isLast: Bool
    /// The outline's row number of the row, counting the sections' headers as `E2EZonesApp.sidebarOutline(of:)`
    /// does, which leaves this row out: so it is the number of rows that list holds.
    var index: Int
    var height: Double
    /// True while the outline selects the row, which it never should.
    var isSelected: Bool
    /// True when the label is drawn in the UI font (Nunito Sans 13.5).
    var usesUIFont: Bool
    /// True when the label and the plus symbol are drawn in the Soft color.
    var usesSoft: Bool
    /// True when the row shows its plus symbol.
    var hasPlus: Bool
    /// True while the row's background is the hover tint (the Pin color).
    var showsHoverTint: Bool

    var description: String {
        "\"\(title)\" last=\(isLast) index=\(index) height=\(height) selected=\(isSelected) "
            + "uiFont=\(usesUIFont) soft=\(usesSoft) plus=\(hasPlus) hover=\(showsHoverTint)"
    }
}

/// The New Tab row that ends the Space's tab list, as a test sees it. Clicking it is
/// `E2ESidebarApp.clickNewTabRow(in:)`.
@MainActor
protocol E2ENewTabRowApp: E2EZonesApp {
    /// The row of the window `page` is in.
    func newTabRow(of page: any E2EPage) throws -> E2ENewTabRowState
    /// Moves the pointer onto the row (or off it), as hovering does.
    func hoverNewTabRow(_ hovered: Bool, in page: any E2EPage) throws
}
