import AppKit
import BowCore

// The folders area of the adapter: E2EFoldersApp over the window's SidebarView, its context menu, its rename field
// and the window's attached sheet.

extension E2ETestApp: E2EFoldersApp {
    func sidebarMenuTitles(row: Int, in page: any E2EPage) throws -> [String] {
        try adapter.requireActive(token, "read a sidebar menu")
        return try E2EAppAdapter.sidebarMenu(row: row, in: page).map { $0.isSeparatorItem ? "-" : $0.title }
    }

    func chooseSidebarMenuItem(_ title: String, row: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose \"\(title)\" in a sidebar menu")
        let items = try E2EAppAdapter.sidebarMenu(row: row, in: page)
        guard let item = items.first(where: { $0.title == title }), let action = item.action,
            NSApp.sendAction(action, to: item.target, from: item)
        else {
            throw E2EError("row \(row)'s menu has no item \"\(title)\": \(items.map(\.title))")
        }
    }

    func doubleClickSidebarRow(_ row: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "double click a sidebar row")
        let sidebar = try E2EAppAdapter.tabPage(page).controller.e2eSidebar
        guard row >= 0, row < sidebar.outlineView.numberOfRows else { throw E2EError("there is no row \(row)") }
        let outline = sidebar.outlineView
        guard outline.target === sidebar, outline.doubleAction == #selector(SidebarView.outlineDoubleClicked(_:)) else {
            throw E2EError("the outline's double click does not reach the sidebar")
        }
        // What the outline's click and double click actions do with the clicked row.
        sidebar.clickRow(row)
        sidebar.doubleClickRow(row)
    }

    func sidebarRenameText(in page: any E2EPage) throws -> String? {
        try adapter.requireActive(token, "read the sidebar rename field")
        guard let row = try E2EAppAdapter.renamingRow(in: page) else { return nil }
        return row.titleField.currentEditor()?.string ?? row.titleField.stringValue
    }

    func typeSidebarRename(_ text: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "type a sidebar rename")
        guard let row = try E2EAppAdapter.renamingRow(in: page),
            let editor = row.titleField.currentEditor() as? NSTextView
        else { throw E2EError("no name is being edited in the sidebar") }
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    func clickSidebarDisclosure(row: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click a disclosure triangle")
        let sidebar = try E2EAppAdapter.tabPage(page).controller.e2eSidebar
        let outline = sidebar.outlineView
        guard row >= 0, row < outline.numberOfRows, let node = outline.item(atRow: row),
            sidebar.outlineView(outline, shouldShowOutlineCellForItem: node)
        else { throw E2EError("row \(row) has no disclosure triangle") }
        // What the triangle does: it opens or closes the row's item, and the outline tells its delegate.
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    func dragSidebarRow(_ row: Int, onRow target: Int?, childIndex: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "drag a sidebar row")
        let sidebar = try E2EAppAdapter.tabPage(page).controller.e2eSidebar
        guard row >= 0, row < sidebar.outlineView.numberOfRows,
            let id = (sidebar.outlineView.item(atRow: row) as? SidebarNode)?.itemID
        else { throw E2EError("row \(row) is not an item") }
        guard sidebar.dragItem(id, onRow: target, childIndex: childIndex) else {
            let place = target.map { "row \($0)" } ?? "between sections"
            throw E2EError("the sidebar refused to drop row \(row) on \(place) at \(childIndex)")
        }
    }

    func dragSidebarRow(_ row: Int, gapBelowRow gapRow: Int, atXOfRow xRow: Int, in page: any E2EPage) throws -> Int {
        try adapter.requireActive(token, "drag a sidebar row into a gap")
        let sidebar = try E2EAppAdapter.tabPage(page).controller.e2eSidebar
        guard let outline = sidebar.outlineView as? SidebarOutlineView else { throw E2EError("no sidebar outline") }
        let rows = 0..<outline.numberOfRows
        guard rows.contains(row), rows.contains(gapRow), rows.contains(xRow),
            let id = (outline.item(atRow: row) as? SidebarNode)?.itemID, let above = outline.item(atRow: gapRow)
        else { throw E2EError("rows \(row), \(gapRow) and \(xRow) are not all rows") }
        // The outline's own proposal for the gap: the open folder's first slot, else right after the row above.
        let proposed: (item: Any?, childIndex: Int) =
            outline.isExpandable(above) && outline.isItemExpanded(above)
            ? (above, 0) : (outline.parent(forItem: above), outline.childIndex(forItem: above) + 1)
        // A person aims at the icon, 8 points into the row's cell.
        let pointerX = outline.frameOfCell(atColumn: 0, row: xRow).minX + 8
        // What validateDrop does with it: retarget the level, then resolve the drop the outline shows its gap at.
        let target = outline.retargetedDrop(
            proposedItem: proposed.item, childIndex: proposed.childIndex, pointerX: pointerX)
        guard let proposal = sidebar.proposeDrop(of: id, on: target.item as? SidebarNode, childIndex: target.childIndex)
        else { throw E2EError("the sidebar refused to drop row \(row) below row \(gapRow) at row \(xRow)'s x") }
        let gapLevel = outline.level(forItem: proposal.node) + 1
        guard sidebar.acceptDrop(of: id, on: proposal.node, childIndex: proposal.childIndex) else {
            throw E2EError("the sidebar did not take the drop of row \(row) below row \(gapRow)")
        }
        return gapLevel
    }

    func sidebarRowHeights(of page: any E2EPage) throws -> [Double] {
        try adapter.requireActive(token, "read the sidebar's row heights")
        let outline = try E2EAppAdapter.tabPage(page).controller.e2eSidebar.outlineView
        return (0..<outline.numberOfRows).map { Double(outline.rect(ofRow: $0).height) }
    }

    func sidebarSheet(in page: any E2EPage) throws -> E2ESheet? {
        try adapter.requireActive(token, "read a window's sheet")
        guard let attached = try E2EAppAdapter.tabPage(page).controller.window?.attachedSheet,
            let view = attached.contentView
        else { return nil }
        var sheet = E2ESheet(texts: [], buttons: [])
        for subview in E2EAppAdapter.allSubviews(of: view) where !subview.isHiddenOrHasHiddenAncestor {
            if let button = subview as? NSButton {
                sheet.buttons.append(button.title)
                // Return presses the button whose key is Return, or the sheet's default button.
                if button.keyEquivalent == "\r" || attached.defaultButtonCell === button.cell {
                    sheet.returnButton = button.title
                }
            } else if let field = subview as? NSTextField, !field.isEditable, !field.stringValue.isEmpty {
                sheet.texts.append(field.stringValue)
            }
        }
        return sheet
    }

    func clickSheetButton(_ title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click \"\(title)\" on a window's sheet")
        guard let view = try E2EAppAdapter.tabPage(page).controller.window?.attachedSheet?.contentView else {
            throw E2EError("the window has no sheet")
        }
        guard
            let button = E2EAppAdapter.allSubviews(of: view).lazy.compactMap({ $0 as? NSButton })
                .first(where: { $0.title == title && $0.isEnabled }),
            let action = button.action, NSApp.sendAction(action, to: button.target, from: button)
        else { throw E2EError("the sheet has no button \"\(title)\" to click") }
    }
}

extension E2EAppAdapter {
    /// The context menu of row `row` in `page`'s window, as the outline builds it when the row is right-clicked.
    static func sidebarMenu(row: Int, in page: any E2EPage) throws -> [NSMenuItem] {
        let sidebar = try tabPage(page).controller.e2eSidebar
        guard row >= 0, row < sidebar.outlineView.numberOfRows else { throw E2EError("there is no row \(row)") }
        return sidebar.menuItems(forRow: row)
    }

    /// The folder or split row whose name is being edited, nil when none is.
    static func renamingRow(in page: any E2EPage) throws -> SidebarGroupRow? {
        let outline = try tabPage(page).controller.e2eSidebar.outlineView
        return (0..<outline.numberOfRows).lazy
            .compactMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: false) as? SidebarGroupRow }
            .first(where: \.isRenaming)
    }

    /// `view`'s subviews at every depth, in drawing order.
    static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }
}
