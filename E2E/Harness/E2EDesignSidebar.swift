import Foundation

/// The sidebar list's part of `E2EDesignLook`: the active tab's row, the Space name and the folder indent. Read by
/// E2E/Harness/E2EAppAdapter+DesignSidebar.swift.
struct E2EDesignSidebarLook {
    /// The active tab's row: its lifted background, its shadow opacity, its height, corner radius, and its title's
    /// color and weight.
    var selectedRowBackground: String?
    var selectedRowShadowOpacity: Double
    var selectedRowHeight: Double
    var selectedRowCornerRadius: Double
    var selectedRowText: String?
    var selectedRowBold: Bool
    /// Frames in the sidebar's outline (top left origin, x from the sidebar's leading edge), zero when not shown: the
    /// Space name and the first row of the Space's tabs.
    var spaceNameFrame: CGRect
    var firstTabRowFrame: CGRect
    /// The leading x of the icon of the first tab directly in a section and of the first tab inside a folder, in the
    /// outline, and that second row's height; 0 without such a row.
    var topIconX: Double
    var childIconX: Double
    var childRowHeight: Double
}
