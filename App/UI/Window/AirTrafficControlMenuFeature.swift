import AppKit
import BowCore

/// Bow > Air Traffic Control…, which opens the routing rules editor (`AirTrafficControlEditor`, run by the app's
/// `AirTrafficControl`). Arc keeps Air Traffic Control in its settings; Bow has no settings window yet, so the item
/// sits in the app menu, where settings go on macOS. The item targets this class, not the responder chain, so it
/// works with no browser window open (the editor itself key, or every window closed).
@MainActor
final class AirTrafficControlMenuFeature: NSResponder, BrowserWindowFeature {
    init(window: BrowserWindowController) {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The title of the menu item.
    static let title = "Air Traffic Control…"

    static func addMenuItems(to menus: MainMenu.Menus) {
        let item = NSMenuItem(title: title, action: #selector(showEditor(_:)), keyEquivalent: "")
        item.target = AirTrafficControlMenuFeature.self
        // In its own group after the first one (About Bow and the default browser item), where an app's settings go.
        guard let separator = menus.app.items.firstIndex(where: \.isSeparatorItem) else {
            menus.app.addItem(item)
            return
        }
        menus.app.insertItem(item, at: separator + 1)
        menus.app.insertItem(.separator(), at: separator + 2)
    }

    @objc static func showEditor(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showAirTrafficControl()
    }
}
