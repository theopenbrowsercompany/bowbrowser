import Foundation

/// Light or dark, the appearance a palette is drawn for.
public enum SpacePaletteAppearance: Hashable, Sendable, CaseIterable {
    case light
    case dark
}

/// Every chrome color of a Space, derived from its theme the way Arc derives a palette from a theme color
/// (https://arc.net/colors.html names the roles: background, backgroundExtra, foregroundPrimary, foregroundSecondary,
/// foregroundTertiary, focus, hover, title and subtitle; the page gives names only, so the derivation below is
/// Bow's own): every neutral is the theme's hue, so rows, tiles, the field and dividers tint with the Space instead
/// of staying cream.
///
/// The default theme returns the brand kit colors exactly, the cream `#FFF3E6` and the cocoa `#2A1710` background
/// with the `#3A1F14` and `#FFF3E6` title, so a Space nobody themed looks as it always did.
public struct SpacePalette: Hashable, Sendable {
    /// The window's surface: the sidebar and the frame around the page.
    public let background: SpaceTintColor
    /// A second surface a step away from `background`, where a gradient or a raised area needs one.
    public let backgroundExtra: SpaceTintColor
    /// The Space's name above its tabs.
    public let title: SpaceTintColor
    /// Text under a title.
    public let subtitle: SpaceTintColor
    /// Tab titles and other text that must be read: at least 7:1 against `background`.
    public let foregroundPrimary: SpaceTintColor
    /// Secondary text, such as a tab's host: at least 4.5:1 against `background`.
    public let foregroundSecondary: SpaceTintColor
    /// Placeholders and disabled text, and glyphs that are not read as text.
    public let foregroundTertiary: SpaceTintColor
    /// A row under the pointer.
    public let hover: SpaceTintColor
    /// The selected tab's row.
    public let selectedFill: SpaceTintColor
    /// A tile, such as a Favorite.
    public let tileFill: SpaceTintColor
    /// The address and search field.
    public let fieldFill: SpaceTintColor
    /// A line between sections.
    public let divider: SpaceTintColor
    /// The focus ring and the accent: at least 3:1 against `background`.
    public let focus: SpaceTintColor
    /// How much of the Space's backdrop (the theme's gradient behind the chrome) shows, from 0 to 1.
    /// The default theme has none.
    public let backdropOpacity: Double

    /// The palette of `theme` drawn in `appearance`.
    public init(theme: SpaceTheme, appearance: SpacePaletteAppearance) {
        let dark = appearance == .dark
        let background: SpaceTintColor
        let ink: SpaceTintColor
        let hue: Double
        let saturation: Double
        if theme == .default {
            background = SpaceTintColor(try! SpaceColor(hex: dark ? "#2A1710" : "#FFF3E6"))
            ink = SpaceTintColor(try! SpaceColor(hex: dark ? "#FFF3E6" : "#3A1F14"))
            let base = SpaceTintColor(try! SpaceColor(hex: "#FFF3E6")).hsl
            hue = base.hue
            saturation = 0.9
        } else {
            let primary = SpaceTintColor(theme.primaryColor).hsl
            hue = primary.hue
            // Keep enough saturation that the hue survives 8 bit rounding, and not so much that the surface shouts.
            saturation = min(max(primary.saturation, 0.3), 0.8)
            background = SpaceTintColor(
                hue: hue, saturation: dark ? saturation * 0.6 : saturation, lightness: dark ? 0.13 : 0.92)
            ink = SpaceTintColor(
                hue: hue, saturation: saturation * 0.7, lightness: dark ? 0.95 : 0.14)
        }
        let white = SpaceTintColor(red: 1, green: 1, blue: 1)
        let black = SpaceTintColor(red: 0, green: 0, blue: 0)

        self.background = background
        backgroundExtra = background.mixed(with: dark ? white : black, fraction: 0.05)
        title = ink
        foregroundPrimary = ink
        foregroundSecondary = ink.mixed(with: background, fraction: 0.28)
        subtitle = foregroundSecondary
        foregroundTertiary = ink.mixed(with: background, fraction: 0.5)
        hover = background.mixed(with: ink, fraction: 0.07)
        selectedFill = background.mixed(with: white, fraction: dark ? 0.12 : 0.6)
        tileFill = background.mixed(with: white, fraction: dark ? 0.07 : 0.4)
        fieldFill = background.mixed(with: white, fraction: dark ? 0.1 : 0.7)
        divider = background.mixed(with: ink, fraction: 0.12)
        focus = SpaceTintColor(hue: hue, saturation: max(saturation, 0.6), lightness: dark ? 0.65 : 0.38)
        backdropOpacity = theme == .default ? 0 : (dark ? 0.4 : 0.5)
    }
}
