import AppKit

/// Bow's look in one place: the brand's colors as light and dark tokens, the radii, the shadow and the spacing.
/// The palette comes from the brand kit (`tokens/colors.css`, the Apricot Jam palette); each token resolves to its
/// light or dark value with the appearance it is drawn in.
enum BowBrand {
    // MARK: Tokens (light / dark)

    /// The window's frame: the one surface behind the sidebar and the window buttons.
    static let frame = dynamic(light: 0xFFF3E6, dark: 0x2A1710)
    /// Primary text: tab titles.
    static let text = dynamic(light: 0x3A1F14, dark: 0xFFF3E6)
    /// Secondary text and icons: the Space name, New Tab, the window's navigation buttons, inactive Space dots.
    static let soft = dynamic(light: 0x7A5A48, dark: 0xC9A891)
    /// The active tab's row.
    static let active = dynamic(light: 0xFFFFFF, dark: 0x3D2519)
    /// Favorite tiles and the hovered row.
    static let pin = dynamic(light: 0xFCE7D3, dark: 0x3A2318)
    /// Lines and dividers.
    static let line = dynamic(light: 0xF0DCC8, dark: 0x4A2F22)
    /// The page card and the command bar's panel, White in both appearances.
    static let page = color(0xFFFFFF)
    /// Jam: the active Space's dot.
    static let accent = color(0xE8743B)
    /// Apricot: the ring around the active Space's dot.
    static let ring = color(0xFFC08A)
    /// Jam Deep: filled buttons, with white text.
    static let button = color(0xB84E1B)
    /// Night: the shadow's color.
    static let shadow = color(0x2A1710)

    // MARK: Fonts

    /// The brand's UI face, bundled in Resources/Fonts and registered at launch through Info.plist's
    /// ATSApplicationFontsPath (Apple's Information Property List Key Reference).
    static let uiFamily = "Nunito Sans"
    /// The display face, for the start screen greeting only.
    static let displayFamily = "Fredoka"
    /// The size of UI text.
    static let uiSize: CGFloat = 13.5
    /// The group label (the Space name): 11 point bold, uppercase, letter spacing 0.8.
    static let labelSize: CGFloat = 11
    static let labelKern: CGFloat = 0.8
    /// The greeting's size, 40 points, in Fredoka 600. A later item draws it; nothing does yet.
    static let displaySize: CGFloat = 40

    /// The UI font at `size` (13.5 points by default) and `weight`: the bundled variable font's named instance, or
    /// the system font when the font did not load.
    static func ui(_ size: CGFloat = uiSize, weight: NSFont.Weight = .regular) -> NSFont {
        font(family: uiFamily, size: size, weight: weight)
    }

    /// The display font: Fredoka 600 at 40 points, or the system font in the same weight when it did not load.
    static func display(_ size: CGFloat = displaySize) -> NSFont {
        font(family: displayFamily, size: size, weight: .semibold)
    }

    private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family { return font }
        return .systemFont(ofSize: size, weight: weight)
    }

    // MARK: Shape

    /// The page card.
    static let radiusCard: CGFloat = 10
    /// Tab rows.
    static let radiusRow: CGFloat = 9
    /// Favorite tiles.
    static let radiusTile: CGFloat = 10
    /// The command bar's panel.
    static let radiusPanel: CGFloat = 14

    /// The one soft shadow under the active row, the page card and the command bar (0 1 3 at 14 percent Night): a
    /// 1 point downward offset and a 3 point blur. A view takes it through its `shadow` property, which AppKit keeps
    /// its layer's shadow in step with.
    static let shadowOpacity: CGFloat = 0.14
    static let shadowBlur: CGFloat = 3
    static let shadowOffset = NSSize(width: 0, height: -1)

    static func softShadow() -> NSShadow {
        let soft = NSShadow()
        soft.shadowColor = shadow.withAlphaComponent(shadowOpacity)
        soft.shadowBlurRadius = shadowBlur
        soft.shadowOffset = shadowOffset
        return soft
    }

    // MARK: Spacing

    /// The page card's inset from the frame.
    static let pageInset: CGFloat = 8
    /// The sidebar's padding: top and leading 14, trailing and bottom 12.
    static let sidebarLeading: CGFloat = 14
    static let sidebarTrailing: CGFloat = 12
    static let sidebarBottom: CGFloat = 12
    /// The gap between the sidebar's blocks.
    static let sidebarGap: CGFloat = 14

    private static func color(_ rgb: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// A color that is `light` in light mode and `dark` in dark mode.
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        let light = color(light)
        let dark = color(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
