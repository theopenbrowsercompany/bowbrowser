import AppKit
import BowCore

// The chrome area of the adapter: E2EChromeApp over the window's CopyURLFeature.

extension E2ETestApp: E2EChromeApp {
    func usePrivatePasteboard(of page: any E2EPage) throws -> any E2EChromePasteboard {
        try adapter.requireActive(token, "use a private pasteboard")
        let feature = try Self.copyFeature(of: page)
        let board = NSPasteboard(name: NSPasteboard.Name("bow.e2e.\(UUID().uuidString)"))
        board.clearContents()
        feature.pasteboard = board
        return PrivatePasteboard(board: board)
    }

    func confirmation(of page: any E2EPage) throws -> E2EChromeConfirmation {
        try adapter.requireActive(token, "read the confirmation")
        let feature = try Self.copyFeature(of: page)
        let view = feature.confirmation
        let content = view.superview
        return E2EChromeConfirmation(
            isShown: !view.isHidden && view.alphaValue > 0 && view.window != nil,
            text: view.accessibilityLabel() ?? "",
            viewCount: content?.subviews.filter { $0 is CopyConfirmationView }.count ?? 0)
    }

    private static func copyFeature(of page: any E2EPage) throws -> CopyURLFeature {
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(CopyURLFeature.self) else {
            throw E2EError("the window has no copy feature")
        }
        return feature
    }
}

extension E2ETestApp: E2EURLFieldApp {
    func urlField(of page: any E2EPage) throws -> E2EURLField {
        try adapter.requireActive(token, "read the URL field")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let field = try Self.urlFieldView(in: controller)
        let sidebar = controller.e2eSidebar
        // Frames as they will be drawn, with any change since the last layout pass laid out.
        sidebar.layoutSubtreeIfNeeded()
        let frame = field.convert(field.bounds, to: nil)
        // The lowest of the top row and the window buttons, in window coordinates (y grows upwards).
        var buttons: [NSRect] = []
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = controller.window?.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor {
                buttons.append(button.convert(button.bounds, to: nil))
            }
        }
        let buttonsBottom = buttons.map(\.minY).min() ?? .greatestFiniteMagnitude
        let rowBottom = sidebar.topRow.convert(sidebar.topRow.bounds, to: nil).minY
        let slot = sidebar.topSlot.convert(sidebar.topSlot.bounds, to: nil)
        let sidebarTop = sidebar.convert(sidebar.bounds, to: nil).maxY
        return E2EURLField(
            text: field.text, isPlaceholder: field.address == nil,
            isShown: field.window != nil && !field.isHiddenOrHasHiddenAncestor,
            isTopRowShown: !sidebar.topRow.isHiddenOrHasHiddenAncestor, size: field.bounds.size,
            isBelowTopRow: frame.maxY <= min(rowBottom, buttonsBottom), contentTop: sidebarTop - slot.maxY,
            contentClearsWindowButtons: slot.maxY <= buttonsBottom)
    }

    func clickURLField(of page: any E2EPage) throws {
        try adapter.requireActive(token, "click the URL field")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let field = try Self.urlFieldView(in: controller)
        guard let window = controller.window, let content = window.contentView else {
            throw E2EError("the window has no content view")
        }
        guard !field.isHiddenOrHasHiddenAncestor else { throw E2EError("the URL field is hidden") }
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let target = content.superview?.hitTest(point) ?? content.hitTest(point)
        guard let target, target === field else {
            let name = target.map { "\(Swift.type(of: $0))" } ?? "nothing"
            throw E2EError("a click at \(point) lands on \(name), not the URL field")
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw E2EError("cannot make a mouse event") }
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
    }

    func toolbarMenuTitle(of page: any E2EPage) throws -> String {
        try adapter.requireActive(token, "read the toolbar menu item")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let action = #selector(ToolbarFeature.toggleToolbar(_:))
        let item = NSApp.mainMenu?.items.lazy.compactMap { $0.submenu }.flatMap(\.items).first { $0.action == action }
        guard let item, let feature = controller.feature(ToolbarFeature.self) else {
            throw E2EError("no menu item hides or shows the toolbar")
        }
        _ = feature.validateMenuItem(item)
        return item.title
    }

    func savedShowsToolbar() throws -> Bool? {
        try adapter.requireActive(token, "read the toolbar setting")
        return AppSettings.defaults.object(forKey: AppSettings.showsToolbarKey) as? Bool
    }

    private static func urlFieldView(in controller: BrowserWindowController) throws -> URLFieldView {
        func find(in view: NSView) -> URLFieldView? {
            if let field = view as? URLFieldView { return field }
            return view.subviews.lazy.compactMap(find(in:)).first
        }
        guard let field = find(in: controller.e2eSidebar) else { throw E2EError("the sidebar has no URL field") }
        return field
    }
}

@MainActor
private final class PrivatePasteboard: E2EChromePasteboard {
    let board: NSPasteboard

    init(board: NSPasteboard) { self.board = board }

    var changeCount: Int { board.changeCount }
    var string: String? { board.string(forType: .string) }
    var url: URL? { board.string(forType: .URL).flatMap(URL.init(string:)) }
    func release() { board.releaseGlobally() }
}
