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

    /// "Ctrl+Cmd+1" for `key` pressed with these modifiers, with a key that has no character by its name
    /// ("Cmd+Up", "F5").
    func shortcut(_ key: String) -> String {
        let name = E2EMenuKey.name(of: key)
        return isEmpty ? name : "\(self)+\(name)"
    }
}

/// The keys a menu shortcut can name that have no printable character, as AppKit writes them in a key equivalent.
/// Letters, digits and symbols are written as themselves ("w", "1", "[").
enum E2EMenuKey {
    static let upArrow = character(0xF700)
    static let downArrow = character(0xF701)
    static let leftArrow = character(0xF702)
    static let rightArrow = character(0xF703)
    static let forwardDelete = character(0xF728)
    static let home = character(0xF729)
    static let end = character(0xF72B)
    static let pageUp = character(0xF72C)
    static let pageDown = character(0xF72D)
    /// Delete (backspace), as AppKit menus write it. A menu may also write it as DEL ("\u{7F}"), which names the
    /// same key.
    static let delete = "\u{8}"
    static let tab = "\t"
    static let `return` = "\r"
    static let escape = "\u{1B}"
    static let space = " "

    /// Function key F`number`, F1 to F35; an empty key, which no menu item has, for any other number.
    static func function(_ number: Int) -> String {
        (1...35).contains(number) ? character(0xF704 + UInt32(number) - 1) : ""
    }

    /// The name a shortcut shows for `key`: "Up", "F5", "Esc", or the key itself.
    static func name(of key: String) -> String {
        if let name = names[key] { return name }
        if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
            (0xF704...0xF726).contains(scalar.value)
        {
            return "F\(scalar.value - 0xF704 + 1)"
        }
        return key
    }

    private static let names: [String: String] = [
        upArrow: "Up", downArrow: "Down", leftArrow: "Left", rightArrow: "Right", forwardDelete: "ForwardDelete",
        home: "Home", end: "End", pageUp: "PageUp", pageDown: "PageDown", delete: "Delete", "\u{7F}": "Delete",
        tab: "Tab", `return`: "Return", escape: "Esc", space: "Space",
    ]

    private static func character(_ value: UInt32) -> String {
        Unicode.Scalar(value).map { String(Character($0)) } ?? ""
    }
}

/// Where a main menu item's shortcut goes in a test window (`E2EMenuApp.menuRoutes(in:)`).
struct E2EMenuRoute: Equatable, CustomStringConvertible {
    var shortcut: String
    var title: String
    /// The class of the object in the test window that handles the item (along the window's responder chain, then
    /// its delegate and its window controller); "refused" for an app or window chrome action a test may not take (quitting, hiding,
    /// minimizing, zooming, full screen); "outside" for an item whose own target is not in the test window; "none"
    /// when nothing in the window handles it.
    var handler: String

    var description: String { "\(shortcut)=\(handler)" }
}

/// The app's menu bar as a test sees it: shortcuts with any modifiers, chosen through the app's main menu as a key
/// press would, never through DevTools.
@MainActor
protocol E2EMenuApp: E2EApp {
    /// The title of the main menu item whose shortcut is `key` with exactly `modifiers`, nil when none has it. A
    /// hidden item has no shortcut unless it allows its key equivalent while hidden, as AppKit reads it, and every
    /// item in a hidden item's submenu has none. An uppercase letter counts as Shift
    /// with that letter, the way AppKit reads a key equivalent, so "W" with Command and "w" with Shift and Command
    /// name the same item. Only letters fold: a symbol is matched as written, so name the symbol the item shows
    /// ("{" with Command, not "[" with Shift and Command). Keys without a printable character are named by
    /// `E2EMenuKey`.
    func menuItemTitle(key: String, modifiers: E2EKeyModifiers) -> String?
    /// Chooses the menu item whose shortcut is `key` with exactly `modifiers`, sent to the first object along the
    /// responder chain of the window `page` is in, then that window's delegate and controller, after the item
    /// validates, as the shortcut does when that window is key. The application and its delegate are never asked, so
    /// an app level fallback cannot stand in for a window command, and a shortcut only the app delegate handles
    /// cannot be chosen in a test. Throws when no item has the shortcut, the item's action is
    /// refused (quitting, hiding, minimizing, zooming or full screen: only `app.quit` quits, through the runner),
    /// nothing in the window handles it, or the item is disabled.
    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, in page: any E2EPage) throws
    /// Where each visible main menu item with a shortcut would go if chosen in the window `page` is in, in menu
    /// order, without choosing any.
    func menuRoutes(in page: any E2EPage) throws -> [E2EMenuRoute]
}
