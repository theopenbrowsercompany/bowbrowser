import AppKit
import BowCore

/// Downloads in a browser window: opens the downloads window from Window > Downloads (Option+Cmd+L). The window
/// hands each engine profile its tabs open in to the app's `DownloadsCenter` as it resolves it (see
/// `AppDelegate.openWindow`), so every profile's downloads are saved and listed.
@MainActor
final class DownloadsFeature: NSResponder, BrowserWindowFeature {
    private let center: DownloadsCenter

    init(window: BrowserWindowController) {
        center = window.appFeatures.require(DownloadsCenter.self)
        super.init()
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
