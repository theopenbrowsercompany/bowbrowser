import AppKit
import BowCore

// The Space drop area of the adapter: E2ESpaceDropApp over the Space icons of the window's footer switcher. The icon's
// own NSDraggingDestination methods get the calls AppKit makes in a drag (draggingEntered, then prepareForDragOperation
// and performDragOperation, or draggingExited), with a real pasteboard item written by the sidebar's own writer and
// a dragging source inside the window's sidebar. No mouse event goes into a tracking loop.

extension E2ETestApp: E2ESpaceDropApp {
    func dragOnSpaceIcon(item: String, space: String, end: E2ESpaceDropEnd, in page: any E2EPage) throws
        -> E2ESpaceDropResult
    {
        try adapter.requireActive(token, "drag a sidebar item on a Space icon")
        return try adapter.dragOnSpaceIcon(item: item, space: space, end: end, in: page)
    }
}

extension E2EAppAdapter {
    func dragOnSpaceIcon(item: String, space: String, end: E2ESpaceDropEnd, in page: any E2EPage) throws
        -> E2ESpaceDropResult
    {
        let controller = try Self.tabPage(page).controller
        let sidebar = controller.e2eSidebar
        let id = SidebarItemID(item)
        guard
            let icon = Self.views(in: sidebar.footer, NSButton.self).first(where: {
                $0.identifier?.rawValue == "space-icon" && $0.accessibilityLabel() == space
            })
        else { throw E2EError("the footer has no icon for the Space \(space)") }
        // The sidebar's own writer for a row, a Favorites tile's for a Favorite.
        let writer: (any NSPasteboardWriting)?
        if let rowWriter = sidebar.dragWriter(for: id) {
            writer = rowWriter
        } else {
            writer = try Self.favoritesGrid(of: page).tiles.first { $0.item == id }?.pasteboardWriter
        }
        guard let writer else { throw E2EError("\(item) has no sidebar row or Favorites tile to drag") }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.bowbrowser.e2e.drag.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])
        guard let window = icon.window else { throw E2EError("the Space icon is in no window") }
        let info = E2EDraggingInfo(
            window: window, source: sidebar.outlineView, pasteboard: pasteboard,
            location: icon.convert(NSPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: nil))
        func ringed() -> Bool { (icon.layer?.borderWidth ?? 0) > 0 && icon.layer?.borderColor != nil }
        let operation = icon.draggingEntered(info)
        let ringedOver = ringed()
        var performed = false
        switch end {
        case .drop:
            if icon.prepareForDragOperation(info) { performed = icon.performDragOperation(info) }
            icon.concludeDragOperation(info)
        case .leave:
            icon.draggingExited(info)
        }
        return E2ESpaceDropResult(
            operation: operation == [] ? "none" : "move", ringedOver: ringedOver, ringedAfter: ringed(),
            performed: performed)
    }
}
