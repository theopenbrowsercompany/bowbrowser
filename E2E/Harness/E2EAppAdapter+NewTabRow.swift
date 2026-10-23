import AppKit

// The New Tab row area of the adapter: E2ENewTabRowApp over the sidebar's last section header.

extension E2ETestApp: E2ENewTabRowApp {
    func newTabRow(of page: any E2EPage) throws -> E2ENewTabRowState {
        try adapter.requireActive(token, "read the New Tab row")
        let (sidebar, row) = try Self.newTabRowView(of: page)
        let outline = sidebar.outlineView
        let index = outline.row(for: row)
        guard index >= 0 else { throw E2EError("the New Tab row has no outline row") }
        var tint: CGColor?
        row.effectiveAppearance.performAsCurrentDrawingAppearance { tint = BowBrand.pin.cgColor }
        return E2ENewTabRowState(
            title: row.titleField.stringValue,
            isLast: index == outline.numberOfRows - 1,
            index: sidebar.rowKinds().prefix(index).filter { !($0.section is NewTabSection) }.count,
            height: Double(outline.rect(ofRow: index).height),
            isSelected: outline.selectedRowIndexes.contains(index),
            usesUIFont: row.titleField.font == BowBrand.ui(),
            usesSoft: row.titleField.textColor == BowBrand.soft && row.iconView.contentTintColor == BowBrand.soft,
            hasPlus: row.iconView.image != nil,
            showsHoverTint: tint != nil && row.backgroundColor == tint)
    }

    func hoverNewTabRow(_ hovered: Bool, in page: any E2EPage) throws {
        try adapter.requireActive(token, "hover the New Tab row")
        try Self.newTabRowView(of: page).1.setHovered(hovered)
    }

    private static func newTabRowView(of page: any E2EPage) throws -> (SidebarView, NewTabRowView) {
        let sidebar = try E2EAppAdapter.tabPage(page).controller.e2eSidebar
        guard let row = sidebar.headerView(of: NewTabSection.self) as? NewTabRowView else {
            throw E2EError("the sidebar has no New Tab row")
        }
        return (sidebar, row)
    }
}
