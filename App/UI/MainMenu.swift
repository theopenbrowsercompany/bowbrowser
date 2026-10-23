import AppKit

/// The menu bar, built in code because the app has no storyboard.
///
/// It makes the top-level menus with the items of the app and the window core, then lets each window feature add
/// its own (`BrowserWindowFeature.addMenuItems(to:)`). Items have nil targets, so AppKit sends their actions along
/// the key window's responder chain: the window controller, then its features, then the app delegate.
@MainActor
enum MainMenu {
    /// The top-level menus, for features to add their items to.
    struct Menus {
        let app = NSMenu(title: "Bow")
        let file = NSMenu(title: "File")
        let edit = NSMenu(title: "Edit")
        let view = NSMenu(title: "View")
        let history = NSMenu(title: "History")
        let window = NSMenu(title: "Window")
        let help = NSMenu(title: "Help")

        /// In menu bar order.
        var all: [NSMenu] { [app, file, edit, view, history, window, help] }
    }

    static func make() -> NSMenu {
        let menus = Menus()
        addAppItems(to: menus.app)
        addFileItems(to: menus.file)
        addEditItems(to: menus.edit)
        addWindowItems(to: menus.window)
        for feature in WindowFeatures.all {
            feature.addMenuItems(to: menus)
        }
        let menu = NSMenu()
        // A menu nothing added to stays out of the menu bar.
        for submenu in menus.all where !submenu.items.isEmpty {
            menu.addItem(item(for: submenu))
        }
        // Once a feature adds a Help item, the menu also gets the system's Help search field.
        if !menus.help.items.isEmpty { NSApp.helpMenu = menus.help }
        return menu
    }

    /// A menu item that opens `menu`, titled like it.
    static func item(for menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.title = menu.title
        item.submenu = menu
        return item
    }

    private static func addAppItems(to menu: NSMenu) {
        menu.addItem(withTitle: "Hide Bow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Bow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Tab commands go to the key window's controller.
    private static func addFileItems(to menu: NSMenu) {
        menu.addItem(
            withTitle: "New Tab", action: #selector(BrowserWindowController.newTab(_:)), keyEquivalent: "t")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close Tab", action: #selector(BrowserWindowController.closeActiveTab(_:)), keyEquivalent: "w")
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
    }

    private static func addEditItems(to menu: NSMenu) {
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }

    private static func addWindowItems(to menu: NSMenu) {
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = menu
    }
}
