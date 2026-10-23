import AppKit

/// Bow's brand values in one place: the Apricot Jam palette, copied exactly from the brand kit's `tokens/colors.css`,
/// the radii and the spacing scale. Views use the role colors (frame, card, text, line), which follow light and dark
/// mode: light mode is Cream grounds with Cocoa text, dark mode is Night grounds with Cream text.
enum BowBrand {
    // MARK: Palette (tokens/colors.css)

    static let cocoa = NSColor(srgbRed: 0x3A / 255, green: 0x1F / 255, blue: 0x14 / 255, alpha: 1)
    static let jam = NSColor(srgbRed: 0xE8 / 255, green: 0x74 / 255, blue: 0x3B / 255, alpha: 1)
    static let apricot = NSColor(srgbRed: 0xFF / 255, green: 0xC0 / 255, blue: 0x8A / 255, alpha: 1)
    static let cream = NSColor(srgbRed: 0xFF / 255, green: 0xF3 / 255, blue: 0xE6 / 255, alpha: 1)
    static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let cocoaSoft = NSColor(srgbRed: 0x7A / 255, green: 0x5A / 255, blue: 0x48 / 255, alpha: 1)
    static let crust = NSColor(srgbRed: 0xF0 / 255, green: 0xDC / 255, blue: 0xC8 / 255, alpha: 1)
    static let night = NSColor(srgbRed: 0x2A / 255, green: 0x17 / 255, blue: 0x10 / 255, alpha: 1)

    // MARK: Roles

    /// The window's frame: the one surface behind the sidebar, the title bar and the page card.
    static let frame = dynamic(light: cream, dark: night)
    /// The page card and the selected sidebar row.
    static let card = dynamic(light: white, dark: cocoa)
    /// Primary text: tab titles, the Space name.
    static let text = dynamic(light: cocoa, dark: cream)
    /// Secondary text and icons: New Tab, the Space switcher, empty state lines.
    static let secondaryText = dynamic(light: cocoaSoft, dark: crust)
    /// Lines and dividers.
    static let line = dynamic(light: crust, dark: cocoaSoft)
    /// The tint under a hovered sidebar row.
    static let hover = dynamic(light: crust, dark: cocoa)

    // MARK: Shape

    /// The small radius: the page card and sidebar rows.
    static let radiusSmall: CGFloat = 14
    /// The card radius.
    static let radiusCard: CGFloat = 24

    /// The spacing scale.
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let space12: CGFloat = 12
    static let space16: CGFloat = 16

    /// A color that is `light` in light mode and `dark` in dark mode.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
