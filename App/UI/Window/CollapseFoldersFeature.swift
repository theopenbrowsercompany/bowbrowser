import AppKit
import BowCore

/// View > Collapse All Folders, and the same action in the command bar: folds every folder of the Space on screen,
/// pinned and today alike, except the ones above the shown tab, which stay open so the tab stays visible
/// (`SidebarStore.collapseAllFolders`). Arc has no shortcut for it, and neither does Bow. The change is one store
/// transaction, so it is saved once, and the item is off while the Space has no folder.
@MainActor
final class CollapseFoldersFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController
    /// How many open folders the last collapse closed, for the e2e check.
    private(set) var lastCollapsedCount = 0

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The title the menu item and the command bar share.
    static let title = "Collapse All Folders"

    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.view.addItem(.separator())
        menus.view.addItem(withTitle: title, action: #selector(collapseAllFolders(_:)), keyEquivalent: "")
    }

    @objc func collapseAllFolders(_ sender: Any?) {
        guard hasFolder else { return NSSound.beep() }
        var count = 0
        window.changeSidebar { store in count = try store.collapseAllFolders() }
        lastCollapsedCount = count
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(collapseAllFolders(_:)): hasFolder
        default: true
        }
    }

    /// Whether the Space on screen holds a folder.
    private var hasFolder: Bool {
        let graph = window.store.graph
        guard let id = graph.activeSpaceID else { return false }
        return graph.items.values.contains { item in
            if case .folder = item.data { return graph.spaceID(containing: item.id) == id }
            return false
        }
    }
}
