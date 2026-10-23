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
        // After About Bow and its separator, where an app's settings go.
        let index = min(2, menus.app.items.count)
        menus.app.insertItem(item, at: index)
        menus.app.insertItem(.separator(), at: index + 1)
    }

    @objc static func showEditor(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.showAirTrafficControl()
    }
}
