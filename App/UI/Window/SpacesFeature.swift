import AppKit
import BowCore

/// Spaces in the menu bar: View > Spaces holds New Space, Rename Space, Delete Space, Previous and Next Space
/// (Cmd+Option+Left and Right) and one item per Space for Ctrl+1 to Ctrl+9, following Arc's published shortcuts.
/// Each acts on the window's own Spaces through its sidebar, so switching slides the outline as the switcher does
/// and never opens another window.
@MainActor
final class SpacesFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func addMenuItems(to menus: MainMenu.Menus) {
        let menu = NSMenu(title: "Spaces")
        menu.addItem(withTitle: "New Space", action: #selector(newSpace(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Rename Space…", action: #selector(renameSpace(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Delete Space…", action: #selector(deleteSpace(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let previous = menu.addItem(
            withTitle: "Previous Space", action: #selector(previousSpace(_:)),
            keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        previous.keyEquivalentModifierMask = [.command, .option]
        let next = menu.addItem(
            withTitle: "Next Space", action: #selector(nextSpace(_:)),
            keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        next.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        for number in 1...SidebarGraph.spaceShortcutLimit {
            let item = menu.addItem(
                withTitle: "Space \(number)", action: #selector(showSpaceNumber(_:)), keyEquivalent: "\(number)")
            item.keyEquivalentModifierMask = .control
            item.tag = number
        }
        menus.view.addItem(.separator())
        menus.view.addItem(MainMenu.item(for: menu))
    }

    /// The window's sidebar, which the Space actions act through.
    private var context: (any SidebarActionContext)? { window.feature(SidebarFeature.self) }

    @objc func newSpace(_ sender: Any?) {
        guard let context else { return }
        SpaceActions.create(context: context)
    }

    @objc func renameSpace(_ sender: Any?) {
        guard let context, let id = context.graph.activeSpaceID else { return }
        SpaceActions.rename(id, context: context, window: window.window)
    }

    @objc func deleteSpace(_ sender: Any?) {
        guard let context, let id = context.graph.activeSpaceID else { return }
        SpaceActions.delete(id, context: context, window: window.window)
    }

    @objc func previousSpace(_ sender: Any?) {
        guard let context else { return }
        SpaceActions.showAdjacent(.previous, context: context)
    }

    @objc func nextSpace(_ sender: Any?) {
        guard let context else { return }
        SpaceActions.showAdjacent(.next, context: context)
    }

    @objc func showSpaceNumber(_ sender: NSMenuItem) {
        guard let context else { return }
        SpaceActions.show(number: sender.tag, context: context)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let graph = window.store.graph
        switch menuItem.action {
        case #selector(showSpaceNumber(_:)):
            // Each number item reads as its Space's name; a number with no Space behind it is disabled.
            let id = graph.spaceID(shortcutNumber: menuItem.tag)
            menuItem.title = id.flatMap { graph.space($0)?.title } ?? "Space \(menuItem.tag)"
            menuItem.state = id != nil && id == graph.activeSpaceID ? .on : .off
            return id != nil
        case #selector(previousSpace(_:)):
            return graph.adjacentSpaceID(.previous) != nil
        case #selector(nextSpace(_:)):
            return graph.adjacentSpaceID(.next) != nil
        case #selector(deleteSpace(_:)):
            return graph.activeSpaceID.map { SpaceActions.canDelete($0, in: graph) } ?? false
        case #selector(renameSpace(_:)):
            return graph.activeSpace != nil
        default:
            return true
        }
    }
}
