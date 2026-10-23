import AppKit
import BowCore

// The command bar area of the adapter: E2ECommandBarApp over the window's CommandBarFeature.

extension E2ETestApp: E2ECommandBarApp {
    func commandBar(of page: any E2EPage) throws -> any E2ECommandBar {
        try adapter.requireActive(token, "find the command bar")
        let page = try E2EAppAdapter.tabPage(page)
        guard let window = page.controller.window else { throw E2EError("the page has no window") }
        return WindowCommandBar(page: page, window: window)
    }

    func tabSummary(of page: any E2EPage) throws -> String {
        let controller = try E2EAppAdapter.tabPage(page).controller
        let graph = controller.store.graph
        guard let space = graph.activeSpace else { return "space=none" }
        let title = { (id: SidebarItemID) -> String in
            if let tab = controller.tabList.tabs.first(where: { controller.sidebarItemID(for: $0.id) == id }),
                !tab.title.isEmpty
            {
                return tab.title
            }
            return graph[id]?.tab?.savedTitle ?? id.rawValue
        }
        let today = graph[space.unpinnedContainerID]?.childrenIDs ?? []
        let active = graph.activeTabID.map(title) ?? "none"
        return "space=\(space.title) today=[\(today.map(title).joined(separator: ","))] active=\(active)"
    }
}

/// E2ECommandBar over a window's command bar. Keys go to the window's first responder as key events, which is where
/// the window would deliver them if it were key.
@MainActor
private final class WindowCommandBar: E2ECommandBar {
    private let page: E2ETabPage
    private let window: NSWindow
    private var feature: CommandBarFeature { page.controller.feature(CommandBarFeature.self)! }
    private var field: NSTextField { feature.panel.field }

    init(page: E2ETabPage, window: NSWindow) {
        self.page = page
        self.window = window
    }

    var isShown: Bool { feature.isOpen && !feature.overlay.isHidden && feature.overlay.window === window }
    var hasKeyboard: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }
    var text: String { field.stringValue }
    var isTextSelected: Bool {
        guard let editor = field.currentEditor() as? NSTextView else { return false }
        let length = (field.stringValue as NSString).length
        return length > 0 && editor.selectedRange() == NSRange(location: 0, length: length)
    }
    var rows: [E2ECommandBarRow] {
        // Read from the rows the panel shows, so a result the view lost would show up as missing.
        feature.panel.rows.map { row in
            let result = row.result
            let kind =
                switch result.kind {
                case .openTab: "tab"
                case .history: "history"
                case .navigation: "navigate"
                case .search: "search"
                }
            return E2ECommandBarRow(kind: kind, title: result.title, url: result.url, space: result.space?.name)
        }
    }
    var selectedRow: Int? { feature.panel.rows.firstIndex { $0.isSelected } }
    var settledQuery: String? { feature.settledQuery }

    func type(_ text: String) throws {
        for character in text {
            try send(String(character), keyCode: 0)
        }
    }

    func press(_ key: E2ECommandBarKey) throws {
        switch key {
        case .up: try send(String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), keyCode: 126)
        case .down: try send(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), keyCode: 125)
        case .enter: try send("\r", keyCode: 36)
        case .escape: try send("\u{1b}", keyCode: 53)
        }
    }

    func clickOutside() throws {
        try page.requireActive("click outside the command bar")
        guard let content = window.contentView else { throw E2EError("the window has no content view") }
        // Over the page, below the panel: where a person would click to dismiss the bar.
        let pageArea = page.controller.pageArea
        let local = NSPoint(x: pageArea.bounds.midX, y: pageArea.isFlipped ? pageArea.bounds.maxY - 20 : 20)
        let point = pageArea.convert(local, to: nil)
        guard let target = content.superview?.hitTest(point) ?? content.hitTest(point) else {
            throw E2EError("nothing in the window is under \(point)")
        }
        guard target === feature.overlay else {
            throw E2EError("a click at \(point) lands on \(Swift.type(of: target)), not outside the command bar")
        }
        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        else { throw E2EError("cannot make a mouse event") }
        target.mouseDown(with: event)
    }

    private func send(_ characters: String, keyCode: UInt16) throws {
        try page.requireActive("press keys in the command bar")
        guard hasKeyboard, let responder = window.firstResponder else {
            let holder = window.firstResponder.map { "\(Swift.type(of: $0))" } ?? "nothing"
            throw E2EError("the keyboard is not in the command bar's field (shown=\(isShown), it is in \(holder))")
        }
        // Arrow keys carry the function key and numeric pad flags, as the keyboard sends them.
        let modifiers: NSEvent.ModifierFlags = keyCode == 125 || keyCode == 126 ? [.function, .numericPad] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard
                let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                )
            else { throw E2EError("cannot make a key event for \(characters.debugDescription)") }
            if type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
        }
    }
}
