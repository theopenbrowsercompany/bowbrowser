import Foundation

/// Modifier keys of a menu item's shortcut, as a test names them.
struct E2EKeyModifiers: OptionSet, Hashable, CustomStringConvertible {
    let rawValue: Int

    static let control = E2EKeyModifiers(rawValue: 1 << 0)
    static let option = E2EKeyModifiers(rawValue: 1 << 1)
    static let shift = E2EKeyModifiers(rawValue: 1 << 2)
    static let command = E2EKeyModifiers(rawValue: 1 << 3)

    /// "Ctrl+Opt+Shift+Cmd", in the order macOS menus show them; "none" for no modifier.
    var description: String {
        let names: [(E2EKeyModifiers, String)] = [
            (.control, "Ctrl"), (.option, "Opt"), (.shift, "Shift"), (.command, "Cmd"),
        ]
        let shown = names.filter { contains($0.0) }.map(\.1)
        return shown.isEmpty ? "none" : shown.joined(separator: "+")
    }

    /// "Ctrl+Cmd+1" for `key` pressed with these modifiers.
    func shortcut(_ key: String) -> String { isEmpty ? key : "\(self)+\(key)" }
}

/// The app's menu bar as a test sees it: shortcuts with any modifiers, chosen through the app's main menu as a key
/// press would, never through DevTools.
@MainActor
protocol E2EMenuApp: E2EApp {
    /// The title of the main menu item whose shortcut is `key` with exactly `modifiers`, nil when none has it. An
    /// uppercase letter counts as Shift with that letter, the way AppKit reads a key equivalent, so "W" with Command
    /// and "w" with Shift and Command name the same item.
    func menuItemTitle(key: String, modifiers: E2EKeyModifiers) -> String?
    /// Chooses the menu item whose shortcut is `key` with exactly `modifiers`, sent along the responder chain of the
    /// window `page` is in after the item validates, as the shortcut does when that window is key. Throws when no
    /// item has the shortcut, nothing in the window handles it, or the item is disabled.
    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, in page: any E2EPage) throws
}
