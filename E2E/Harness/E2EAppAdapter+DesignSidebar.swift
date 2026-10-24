import AppKit
import BowCore

// The design area's sidebar surface: the active tab's lifted row, the Space name and the folder indent.

extension E2EAppAdapter {
    static func sidebarLook(of controller: BrowserWindowController) -> E2EDesignSidebarLook {
        let sidebar = controller.e2eSidebar
        let appearance = controller.window?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let rowView = controller.tabList.activeID
            .flatMap { controller.sidebarItemID(for: $0) }
            .flatMap { sidebar.rowView(for: $0) }
        let liftView = (rowView?.superview as? SidebarRowView)?.liftView
        let liftLayer = liftView?.layer
        let outline = sidebar.outlineView
        func inOutline(_ view: NSView?) -> CGRect { view.map { outline.convert($0.bounds, from: $0) } ?? .zero }
        let spaceName = views(in: outline, NSTextField.self).first { $0.identifier?.rawValue == "space-name" }
        var topIconX = 0.0
        var childIconX = 0.0
        var childRowHeight = 0.0
        var firstTabRow = CGRect.zero
        for row in 0..<outline.numberOfRows {
            let level = outline.level(forRow: row)
            if level == 1, firstTabRow == .zero { firstTabRow = outline.rect(ofRow: row) }
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabSidebarRow else {
                continue
            }
            let iconX = Double(inOutline(cell.iconView).minX)
            if level == 1, topIconX == 0 { topIconX = iconX }
            if level == 2, childIconX == 0 {
                childIconX = iconX
                childRowHeight = Double(outline.rect(ofRow: row).height)
            }
        }
        return E2EDesignSidebarLook(
            selectedRowBackground: liftLayer?.backgroundColor.flatMap { NSColor(cgColor: $0) }.flatMap {
                designHex($0, in: appearance)
            },
            selectedRowShadowOpacity: Double(liftView?.shadow?.shadowColor?.alphaComponent ?? 0),
            selectedRowHeight: Double(rowView?.superview?.frame.height ?? 0),
            selectedRowCornerRadius: Double(liftLayer?.cornerRadius ?? 0),
            selectedRowText: rowView.flatMap { designHex($0.titleField.textColor, in: appearance) },
            selectedRowBold: rowView?.titleField.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
            spaceNameFrame: inOutline(spaceName),
            firstTabRowFrame: firstTabRow,
            topIconX: topIconX,
            childIconX: childIconX,
            childRowHeight: childRowHeight)
    }
}
