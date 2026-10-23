import AppKit
import BowCore

// Context menus and DevTools: the bridge asks for a menu, the delegate decides what it shows, the adapter shows it as a
// native menu at the pointer, and the chosen item runs (in the app first, else here or in the engine).

extension CEFTab {
    #if BOW_E2E  // E2E seam: an e2e run chooses an item itself (by title) instead of showing a menu that waits for a click.
        static var e2eMenuChooser: ((ContextMenuRequest, [String]) -> String?)?
    #endif

    func showDevTools(inspectingAt point: PagePoint?) {
        if let point {
            tab.showDevTools(inspectingAt: CGPoint(x: point.x, y: point.y))
        } else {
            tab.showDevTools()
        }
    }

    func closeDevTools() { tab.closeDevTools() }
    var hasDevTools: Bool { tab.hasDevTools }

    @objc(tab:runContextMenu:completionHandler:)
    func tab(
        _ tab: BowTab, runContextMenu bridgeRequest: BowContextMenuRequest,
        completionHandler: @escaping (Int) -> Void
    ) {
        let request = ContextMenuRequest(bridgeRequest, profileID: profileID, state: state)
        let decision = delegate?.tab(self, decideContextMenu: request) ?? .engineDefault
        let address = state.url
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch decision {
        case .none:
            completionHandler(BowContextMenuRequest.noCommand)
            return
        case .engineDefault:
            Self.add(bridgeRequest.defaultItems, to: menu)
        case .show(let items):
            for (index, item) in items.enumerated() {
                if item.isSeparator {
                    menu.addItem(.separator())
                    continue
                }
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = item.isEnabled
                menuItem.representedObject = index
                menu.addItem(menuItem)
            }
        }
        guard let chosen = choose(from: menu, request: request) else {
            completionHandler(BowContextMenuRequest.noCommand)
            return
        }
        // The page moved on or closed while the menu was open: the choice was made for a page that is gone.
        guard !isClosed, state.url == address else {
            completionHandler(BowContextMenuRequest.noCommand)
            return
        }
        guard case .show(let items) = decision, let index = chosen.representedObject as? Int else {
            completionHandler(chosen.tag)
            return
        }
        guard let command = items[index].command else {
            completionHandler(BowContextMenuRequest.noCommand)
            return
        }
        if delegate?.tab(self, runContextMenuCommand: command, request: request) == true {
            completionHandler(BowContextMenuRequest.noCommand)
            return
        }
        run(command, request: request, completionHandler: completionHandler)
    }

    /// Runs a command the app left to the engine.
    private func run(_ command: ContextMenuCommand, request: ContextMenuRequest, completionHandler: (Int) -> Void) {
        let editing: BowContextMenuRequest.Command? =
            switch command {
            case .undo: .undo
            case .redo: .redo
            case .cut: .cut
            case .copy: .copy
            case .paste: .paste
            case .selectAll: .selectAll
            default: nil
            }
        if let editing {
            completionHandler(editing.rawValue)
            return
        }
        completionHandler(BowContextMenuRequest.noCommand)
        switch command {
        case .copyLinkAddress: Self.copy(request.linkURL)
        case .copyImageAddress: Self.copy(request.imageURL)
        case .back: goBack()
        case .forward: goForward()
        case .reload: reload()
        case .inspect: showDevTools(inspectingAt: request.position)
        case .openLinkInNewTab, .custom, .undo, .redo, .cut, .copy, .paste, .selectAll: break
        }
    }

    /// Shows `menu` at the pointer and returns the item chosen, or nil.
    private func choose(from menu: NSMenu, request: ContextMenuRequest) -> NSMenuItem? {
        #if BOW_E2E  // E2E seam: the harness's chooser stands in for the person.
            if let chooser = Self.e2eMenuChooser {
                let enabled = menu.items.filter { !$0.isSeparatorItem && $0.isEnabled }
                let title = chooser(request, menu.items.filter { !$0.isSeparatorItem }.map(\.title))
                return enabled.first { $0.title == title }
            }
        #endif
        let picker = ContextMenuPicker()
        picker.target(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return picker.chosen
    }

    private static func add(_ items: [BowContextMenuItem], to menu: NSMenu) {
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.isEnabled = item.isEnabled
            menuItem.state = item.isChecked ? .on : .off
            menuItem.tag = item.commandID
            if !item.submenu.isEmpty {
                let submenu = NSMenu(title: item.title)
                submenu.autoenablesItems = false
                add(item.submenu, to: submenu)
                menuItem.submenu = submenu
            }
            menu.addItem(menuItem)
        }
    }

    private static func copy(_ url: URL?) {
        guard let url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}

/// Records the item chosen from a menu shown at the pointer.
@MainActor
private final class ContextMenuPicker: NSObject {
    private(set) var chosen: NSMenuItem?

    func target(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                target(submenu)
            } else {
                item.target = self
                item.action = #selector(pick(_:))
            }
        }
    }

    @objc func pick(_ sender: NSMenuItem) {
        chosen = sender
    }
}

extension ContextMenuRequest {
    init(_ request: BowContextMenuRequest, profileID: ProfileID, state: EngineTabState) {
        let flags = request.editFlags
        var editFlags: ContextMenuEditFlags = []
        if flags.contains(.canUndo) { editFlags.insert(.canUndo) }
        if flags.contains(.canRedo) { editFlags.insert(.canRedo) }
        if flags.contains(.canCut) { editFlags.insert(.canCut) }
        if flags.contains(.canCopy) { editFlags.insert(.canCopy) }
        if flags.contains(.canPaste) { editFlags.insert(.canPaste) }
        if flags.contains(.canDelete) { editFlags.insert(.canDelete) }
        if flags.contains(.canSelectAll) { editFlags.insert(.canSelectAll) }
        self.init(
            profileID: profileID,
            position: PagePoint(x: request.location.x, y: request.location.y),
            pageURL: request.pageURL,
            frameURL: request.frameURL,
            linkURL: request.targets.contains(.link) ? request.linkURL : nil,
            imageURL: request.mediaType == .image ? request.sourceURL : nil,
            selectionText: request.selectionText,
            isEditable: request.isEditable,
            editFlags: editFlags,
            canGoBack: state.canGoBack,
            canGoForward: state.canGoForward)
    }
}
