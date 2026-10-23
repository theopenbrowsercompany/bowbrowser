import AppKit
import BowCore

/// View > Hide Toolbar and Show Toolbar (Cmd+Shift+D, the name and keys of Arc's View > Show Toolbar): hides the
/// sidebar's top row (back, forward and reload) and its URL field for the most minimal chrome, or shows them again.
/// The window's close, minimize and zoom buttons stay. Cmd+L still opens the command bar on the current address.
///
/// The choice is one app setting (`AppSettings.showsToolbar`), kept across launches: every open window follows it.
/// The URL field hides itself from the same setting; this feature hides the top row.
@MainActor
final class ToolbarFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(toolbarVisibilityChanged(_:)), name: AppSettings.toolbarVisibilityChanged,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func addMenuItems(to menus: MainMenu.Menus) {
        menus.view.addItem(.separator())
        // An uppercase key equivalent is Shift with that letter. The title follows the setting in validation.
        menus.view.addItem(withTitle: "Hide Toolbar", action: #selector(toggleToolbar(_:)), keyEquivalent: "D")
    }

    @objc func toggleToolbar(_ sender: Any?) {
        AppSettings.showsToolbar.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleToolbar(_:)) {
            menuItem.title = AppSettings.showsToolbar ? "Hide Toolbar" : "Show Toolbar"
        }
        return true
    }

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard KeyShortcuts.shortcut(for: event, claimedBy: .toolbar) == .toggleToolbar else { return false }
        AppSettings.showsToolbar.toggle()
        return true
    }

    /// Called once as the window opens, after every feature exists, so the sidebar is there to change.
    func activeSpaceChanged(_ space: SidebarSpace) {
        apply()
    }

    @objc private func toolbarVisibilityChanged(_ notification: Notification) {
        apply()
    }

    private func apply() {
        guard let sidebar = window.feature(SidebarFeature.self)?.sidebar else { return }
        let hidden = !AppSettings.showsToolbar
        if sidebar.topRow.isHidden != hidden { sidebar.topRow.isHidden = hidden }
    }
}
