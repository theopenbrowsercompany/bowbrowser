import AppKit
import BowCore

// The pointer drag area of the adapter: E2EPointerDragApp over the window's views. A drag of a sidebar row starts at
// the row's center and is let go at a window point; the views under those points get the drag the way AppKit hands it
// to a drop destination (entered, updated, then prepared, performed and concluded, or exited), with a dragging info
// whose location is the point, so the outline resolves the drop position from the pointer itself.

extension E2ETestApp: E2EPointerDragApp {
    func pointerDragSidebarRow(_ title: String, to target: E2EPointerTarget, in page: any E2EPage) throws
        -> E2EPointerDrop
    {
        try adapter.requireActive(token, "drag row \(title) to \(target)")
        return try adapter.pointerDragSidebarRow(title, to: target, in: page)
    }
}

extension E2EAppAdapter {
    func pointerDragSidebarRow(_ title: String, to target: E2EPointerTarget, in page: any E2EPage) throws
        -> E2EPointerDrop
    {
        let controller = try Self.tabPage(page).controller
        let sidebar = controller.e2eSidebar
        let outline = sidebar.outlineView
        guard let window = controller.window, let root = window.contentView?.superview else {
            throw E2EError("the window has no views")
        }
        let row = try Self.outlineRow(titled: title, in: sidebar)
        guard let node = outline.item(atRow: row) as? SidebarNode, node.itemID != nil,
            let writer = sidebar.outlineView(outline, pasteboardWriterForItem: node)
        else { throw E2EError("row \(title) cannot be dragged") }

        let start = Self.windowPoint(row: row, fraction: 0.5, in: outline)
        guard let hit = root.hitTest(start), hit.isDescendant(of: outline) else {
            throw E2EError("something covers row \(title) at \(start)")
        }
        let end: NSPoint
        switch target {
        case .row(let other, let fraction):
            end = Self.windowPoint(
                row: try Self.outlineRow(titled: other, in: sidebar), fraction: fraction, in: outline)
        case .page:
            // The middle of the area beside the sidebar, where the page shows.
            let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
            let content = root.bounds
            end = NSPoint(x: (sidebarFrame.maxX + content.maxX) / 2, y: content.midY)
            if let view = root.hitTest(end), view.isDescendant(of: sidebar) {
                throw E2EError("the point beside the sidebar at \(end) is in the sidebar")
            }
        }

        // A pasteboard of its own, released when the drag ends, so nothing outlives it.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.bowbrowser.e2e.drag.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])
        let info = E2EDraggingInfo(window: window, source: outline, pasteboard: pasteboard, location: start)

        // What the outline's drag session tells the sidebar as the drag begins and ends, dropped or not.
        sidebar.itemDragBegan()
        defer { sidebar.itemDragEnded() }
        var current = Self.dropDestination(at: start, in: root)
        _ = current?.draggingEntered?(info)
        info.draggingLocation = end
        let landing = Self.dropDestination(at: end, in: root)
        if landing !== current {
            current?.draggingExited?(info)
            current = landing
            _ = current?.draggingEntered?(info)
        }
        guard let destination = current else { return E2EPointerDrop(destination: nil, accepted: false) }
        let operation = destination.draggingUpdated?(info) ?? []
        var accepted = false
        if operation.isEmpty {
            destination.draggingExited?(info)
        } else {
            accepted =
                destination.prepareForDragOperation?(info) ?? true
                && destination.performDragOperation?(info) ?? false
            destination.concludeDragOperation?(info)
        }
        destination.draggingEnded?(info)
        return E2EPointerDrop(destination: String(describing: type(of: destination)), accepted: accepted)
    }

    /// The outline row of the first sidebar item titled `title` (a tab, folder or split, not a section header).
    private static func outlineRow(titled title: String, in sidebar: SidebarView) throws -> Int {
        let outline = sidebar.outlineView
        for row in 0..<outline.numberOfRows where (outline.item(atRow: row) as? SidebarNode)?.itemID != nil {
            let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
            let shown =
                (view as? TabSidebarRow)?.titleField.stringValue ?? (view as? SidebarGroupRow)?.titleField.stringValue
            if shown == title { return row }
        }
        throw E2EError("the sidebar has no row titled \(title)")
    }

    /// The point `fraction` of the way down row `row` (0 its top edge, 1 its bottom edge), in window coordinates.
    private static func windowPoint(row: Int, fraction: Double, in outline: NSOutlineView) -> NSPoint {
        let rect = outline.rect(ofRow: row)
        let offset = rect.height * CGFloat(min(max(fraction, 0), 1))
        let y = outline.isFlipped ? rect.minY + offset : rect.maxY - offset
        return outline.convert(NSPoint(x: rect.midX, y: y), to: nil)
    }

    /// The view under `point` (window coordinates) that takes sidebar drags, or its nearest ancestor that does, nil
    /// when none does, as AppKit picks the drop destination under the pointer.
    private static func dropDestination(at point: NSPoint, in root: NSView) -> (any NSDraggingDestination)? {
        var view = root.hitTest(point)
        while let candidate = view {
            if candidate.registeredDraggedTypes.contains(SidebarView.dragType) { return candidate }
            view = candidate.superview
        }
        return nil
    }
}

/// The dragging info a pointer drag hands its destinations: the window point the pointer is at, the dragged row's
/// pasteboard and its source view, and a move as the only operation, as the outline's own drags offer.
final class E2EDraggingInfo: NSObject, NSDraggingInfo {
    private let window: NSWindow
    private let source: NSView
    private let pasteboard: NSPasteboard
    var draggingLocation: NSPoint
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(window: NSWindow, source: NSView, pasteboard: NSPasteboard, location: NSPoint) {
        self.window = window
        self.source = source
        self.pasteboard = pasteboard
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
