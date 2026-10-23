import AppKit
import BowCore

/// File > Import from Arc…, which opens the import wizard (`ArcImportWizard`, run by the app's `ArcImportFeature`) as
/// a sheet on the window. The item is off while this window shows another sheet or a wizard is open anywhere.
@MainActor
final class ImportMenuFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The title of the menu item.
    static let title = "Import from Arc…"

    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.file.addItem(.separator())
        menus.file.addItem(withTitle: title, action: #selector(importFromArc(_:)), keyEquivalent: "")
    }

    @objc func importFromArc(_ sender: Any?) {
        guard !window.appFeatures.require(ArcImportFeature.self).openWizard(in: window) else { return }
        NSSound.beep()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(importFromArc(_:)):
            window.window?.attachedSheet == nil && window.appFeatures.require(ArcImportFeature.self).activeWizard == nil
        default: true
        }
    }
}
