import AppKit
import BowCore

/// Downloads in a browser window: hands the window's profile to the app's `DownloadsCenter`, so the profile's
/// downloads are saved and listed, and opens the downloads window from Window > Downloads (Option+Cmd+L).
@MainActor
final class DownloadsFeature: NSResponder, BrowserWindowFeature {
    private let center: DownloadsCenter

    init(window: BrowserWindowController) {
        center = window.appFeatures.require(DownloadsCenter.self)
        super.init()
        // Before the window's first tab opens, so every download its tabs start has a destination chooser.
        center.observe(window.profile)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.window.addItem(.separator())
        let item = menus.window.addItem(
            withTitle: "Downloads", action: #selector(showDownloads(_:)), keyEquivalent: "l")
        item.keyEquivalentModifierMask = [.command, .option]
    }

    /// Window > Downloads: shows the downloads window, creating it the first time.
    @objc func showDownloads(_ sender: Any?) {
        center.openWindow().showWindow(sender)
    }
}
