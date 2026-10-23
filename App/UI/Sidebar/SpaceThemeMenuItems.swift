import AppKit
import BowCore

/// A Space's theme and icon in the Space menu (the context menu of the Space's name above its tabs, which lists the
/// pinned section's items): "Theme" with Default and the preset colors (`SpaceTint.presets`), each shown with a
/// swatch and the Space's own checked, "Change Icon…", which asks for one emoji in a sheet, and "Remove Icon".
/// Everything goes through the store, so the tint (`SpaceThemeFeature`), the name and the switcher follow from it.
enum SpaceThemeMenuItems: SidebarMenuItems {
    static var kinds: Set<SidebarItemKind> { [.section(.pinned)] }

    static func menuItems(for item: SidebarItemID, context: any SidebarActionContext) -> [NSMenuItem] {
        guard let space = context.graph.spaces.first(where: { $0.pinnedContainerID == item }) else { return [] }
        let id = space.id
        let themes = NSMenu(title: "Theme")
        themes.autoenablesItems = false
        let current = space.resolvedTheme
        let choices = [("Default", SpaceTheme.default)] + SpaceTint.presets.map { ($0.name, $0.theme) }
        for (name, theme) in choices {
            let choice = SidebarMenuItem(title: name) { [weak context] in
                context?.changeSidebar { try $0.setSpaceTheme(id, to: theme == .default ? nil : theme) }
            }
            choice.image = swatch(theme.primaryColor)
            choice.state = theme == current ? .on : .off
            themes.addItem(choice)
        }
        let theme = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        theme.submenu = themes
        let changeIcon = SidebarMenuItem(title: "Change Icon…") { [weak context] in
            guard let context else { return }
            askForIcon(id, context: context)
        }
        let removeIcon = SidebarMenuItem(title: "Remove Icon") { [weak context] in
            context?.changeSidebar { try $0.setSpaceIcon(id, to: nil) }
        }
        removeIcon.isEnabled = space.icon != nil
        return [theme, changeIcon, removeIcon]
    }

    /// A small round swatch of `color` for a menu item.
    private static func swatch(_ color: SpaceColor) -> NSImage {
        let fill = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.accessibilityDescription = color.hex
        return image
    }

    /// Asks for an emoji for Space `id` in a sheet on the sidebar's window, with its current emoji filled in. "Set
    /// Icon" saves one emoji; anything else is refused with a message and the Space keeps its icon. An empty field
    /// changes nothing. While the window shows another sheet it only beeps.
    static func askForIcon(_ id: SidebarSpaceID, context: any SidebarActionContext) {
        guard let space = context.graph.space(id), let window = (context as? SidebarFeature)?.sidebar.window else {
            return
        }
        guard window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Change Icon"
        alert.informativeText =
            "Enter one emoji for “\(space.title)”. Edit > Emoji & Symbols lists them all."
        let field = NSTextField(string: space.icon?.kind == .emoji ? space.icon?.value ?? "" : "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.setAccessibilityLabel("Space icon")
        alert.accessoryView = field
        alert.addButton(withTitle: "Set Icon")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak context, weak window] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let context, context.graph.space(id) != nil else { return }
                let text = field.stringValue
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                do {
                    let icon = try SpaceIcon(emoji: text)
                    context.changeSidebar { try $0.setSpaceIcon(id, to: icon) }
                } catch {
                    // The icon sheet is still attached while this runs: take it down, and say why once it has gone.
                    alert.window.orderOut(nil)
                    let message = "\(error)"
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let window, window.attachedSheet == nil else { return }
                            let refusal = NSAlert()
                            refusal.messageText = message
                            refusal.informativeText = "A Space's icon is one emoji. The icon was not changed."
                            refusal.addButton(withTitle: "OK")
                            refusal.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }
}
