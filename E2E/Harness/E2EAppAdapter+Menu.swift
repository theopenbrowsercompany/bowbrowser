import AppKit

// The menu area of the adapter: E2EMenuApp, and the menu lookup and dispatch every shortcut the harness presses goes
// through (E2EApp.press, E2ESidebarApp.chooseMenuItem(commandKey:) and the find bar).

extension E2EAppAdapter {
    /// The first main menu item, depth first, whose shortcut is `key` with exactly `modifiers`.
    static func menuItem(key: String, modifiers: E2EKeyModifiers) -> NSMenuItem? {
        menuItem(matching: normalized(key: key, modifiers: modifiers), in: NSApp.mainMenu)
    }

    private static func menuItem(matching wanted: Shortcut, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            // A hidden item is skipped, as AppKit skips it for key presses.
            if !item.isHidden, !item.keyEquivalent.isEmpty,
                normalized(key: item.keyEquivalent, modifiers: modifiers(of: item.keyEquivalentModifierMask))
                    == wanted
            {
                return item
            }
            if let found = menuItem(matching: wanted, in: item.submenu) { return found }
        }
        return nil
    }

    private struct Shortcut: Equatable {
        var key: String
        var modifiers: E2EKeyModifiers
    }

    /// An uppercase letter means Shift with that letter, as AppKit reads a key equivalent.
    private static func normalized(key: String, modifiers: E2EKeyModifiers) -> Shortcut {
        let lower = key.lowercased()
        guard lower != key else { return Shortcut(key: key, modifiers: modifiers) }
        return Shortcut(key: lower, modifiers: modifiers.union(.shift))
    }

    private static func modifiers(of mask: NSEvent.ModifierFlags) -> E2EKeyModifiers {
        var modifiers: E2EKeyModifiers = []
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.shift) { modifiers.insert(.shift) }
        if mask.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// Finds the menu item with the shortcut and sends its action the way AppKit does for a key press: to the first
    /// object in the window's responder chain (then its delegate, the application and the app delegate) that handles it, after that object validates the
    /// item. The e2e window never becomes key, so the window is named here instead of AppKit finding the key window.
    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, in page: any E2EPage) throws {
        let controller = try Self.tabPage(page).controller
        guard let window = controller.window else { throw E2EError("the page has no window") }
        let shortcut = modifiers.shortcut(key)
        guard let item = Self.menuItem(key: key, modifiers: modifiers), let action = item.action else {
            throw E2EError("no menu item has the shortcut \(shortcut)")
        }
        var responder: NSResponder? = window.firstResponder
        var target: AnyObject?
        while let current = responder, target == nil {
            if current.responds(to: action) { target = current }
            responder = current.nextResponder
        }
        // After the window's chain, AppKit tries the window's delegate, then the application and its delegate.
        if target == nil, let delegate = window.delegate, delegate.responds(to: action) { target = delegate }
        if target == nil, NSApp.responds(to: action) { target = NSApp }
        if target == nil, let delegate = NSApp.delegate, delegate.responds(to: action) { target = delegate }
        guard let target else { throw E2EError("nothing in the window or the app handles \(item.title)") }
        if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
            throw E2EError("\(item.title) (\(shortcut)) is disabled")
        }
        guard NSApp.sendAction(action, to: target, from: item) else {
            throw E2EError("the menu item \"\(item.title)\" (\(shortcut)) did nothing")
        }
    }
}

extension E2ETestApp: E2EMenuApp {
    func menuItemTitle(key: String, modifiers: E2EKeyModifiers) -> String? {
        E2EAppAdapter.menuItem(key: key, modifiers: modifiers)?.title
    }

    func chooseMenuItem(key: String, modifiers: E2EKeyModifiers, in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose the menu item for \(modifiers.shortcut(key))")
        try adapter.chooseMenuItem(key: key, modifiers: modifiers, in: page)
    }
}
