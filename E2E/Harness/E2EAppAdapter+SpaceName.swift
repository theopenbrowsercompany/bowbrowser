import AppKit
import BowCore

// The Space name area of the adapter: E2ESpaceNameApp over the Space name view in the window's SidebarView outline and
// the sheet on its window. Clicks go to the view under the point with mouse events, and keys to the sheet as a key
// equivalent, the way AppKit routes them, without the window becoming key.

extension E2ETestApp: E2ESpaceNameApp {
    func doubleClickSpaceName(in page: any E2EPage) throws {
        try adapter.requireActive(token, "double click the Space name")
        try adapter.doubleClickSpaceName(in: page)
    }

    func sheetField(in page: any E2EPage) throws -> (text: String, allSelected: Bool)? {
        try adapter.sheetField(in: page)
    }

    func typeInSheet(_ text: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "type into a sheet")
        try adapter.typeInSheet(text, in: page)
    }

    func pressSheetKey(_ key: E2ESheetKey, in page: any E2EPage) throws {
        try adapter.requireActive(token, "press \(key.rawValue) in a sheet")
        try adapter.pressSheetKey(key, in: page)
    }
}

extension E2EAppAdapter {
    func doubleClickSpaceName(in page: any E2EPage) throws {
        let controller = try Self.tabPage(page).controller
        guard let window = controller.window, let root = window.contentView?.superview,
            let nameView = Self.views(in: controller.e2eSidebar.outlineView, SpaceNameView.self).first,
            !nameView.isHiddenOrHasHiddenAncestor
        else { throw E2EError("the sidebar shows no Space name") }
        let point = nameView.convert(NSPoint(x: nameView.bounds.midX, y: nameView.bounds.midY), to: nil)
        // The view under the pointer, or the Space name itself when its label is: a label passes clicks on to it.
        guard let hit = root.hitTest(point), hit.isDescendant(of: nameView) else {
            throw E2EError("something covers the Space name at \(point)")
        }
        func event(_ type: NSEvent.EventType, clickCount: Int) throws -> NSEvent {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
                    pressure: type == .leftMouseDown ? 1 : 0)
            else { throw E2EError("cannot make a mouse event") }
            return event
        }
        for clickCount in 1...2 {
            let down = try event(.leftMouseDown, clickCount: clickCount)
            let up = try event(.leftMouseUp, clickCount: clickCount)
            // The release waits in the event queue before the press is handled, as a real one does: a press the view
            // passes on to the outline runs the outline's tracking loop, which reads events until the release.
            NSApp.postEvent(up, atStart: false)
            nameView.mouseDown(with: down)
            // A press nothing tracked leaves the release queued: it goes to the view here, and leaves the queue.
            if let queued = NSApp.nextEvent(
                matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
            {
                guard queued.windowNumber == window.windowNumber else {
                    NSApp.postEvent(queued, atStart: true)
                    continue
                }
                nameView.mouseUp(with: queued)
            }
        }
    }

    func sheetField(in page: any E2EPage) throws -> (text: String, allSelected: Bool)? {
        guard let sheet = try Self.tabPage(page).controller.window?.attachedSheet, let content = sheet.contentView,
            let field = Self.views(in: content, NSTextField.self).first(where: \.isEditable)
        else { return nil }
        Self.emulateKey(sheet)
        guard let editor = field.currentEditor() else { return (field.stringValue, false) }
        let length = (editor.string as NSString).length
        return (editor.string, editor.selectedRange == NSRange(location: 0, length: length))
    }

    func typeInSheet(_ text: String, in page: any E2EPage) throws {
        guard let sheet = try Self.tabPage(page).controller.window?.attachedSheet, let content = sheet.contentView,
            let field = Self.views(in: content, NSTextField.self).first(where: \.isEditable)
        else { throw E2EError("no sheet with a text field is up") }
        Self.emulateKey(sheet)
        guard let editor = field.currentEditor() as? NSTextView else {
            throw E2EError("the sheet's field is not being edited")
        }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    /// Gives `sheet` the focus it takes when it becomes key: an e2e window never becomes key, so its sheet's first
    /// responder (the field the sheet starts in, which selects its text) is set here, once, the way `E2EPage`
    /// emulates focus for a page. A sheet that already has a first responder keeps it.
    private static func emulateKey(_ sheet: NSWindow) {
        guard sheet.firstResponder === sheet, let first = sheet.initialFirstResponder else { return }
        sheet.makeFirstResponder(first)
    }

    func pressSheetKey(_ key: E2ESheetKey, in page: any E2EPage) throws {
        guard let sheet = try Self.tabPage(page).controller.window?.attachedSheet else {
            throw E2EError("no sheet is up")
        }
        Self.emulateKey(sheet)
        let (characters, keyCode) = key.event
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: sheet.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        else { throw E2EError("cannot make a key event for \(key.rawValue)") }
        // Buttons take their key equivalents through the window, Escape's Cancel among them.
        if sheet.performKeyEquivalent(with: event) { return }
        // Return goes to the window's default button, which AppKit presses only for the key window, so it is
        // pressed here for the sheet of a window that never becomes key.
        guard key == .returnKey, let cell = sheet.defaultButtonCell, cell.isEnabled,
            let button = cell.controlView as? NSButton, !button.isHiddenOrHasHiddenAncestor
        else { throw E2EError("nothing in the sheet takes \(key.rawValue)") }
        button.performClick(nil)
    }
}
