import Foundation

/// An opaque color as sRGB channels from 0 to 1, for the window's tint.
public struct SpaceTintColor: Hashable, Sendable, CustomStringConvertible {
    public let red: Double
    public let green: Double
    public let blue: Double

    /// Channels outside 0 to 1 are clamped, and a channel that is not a number counts as 0.
    public init(red: Double, green: Double, blue: Double) {
        func clamp(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
        self.red = clamp(red)
        self.green = clamp(green)
        self.blue = clamp(blue)
    }

    /// The color of a theme's hex value.
    public init(_ color: SpaceColor) {
        self.init(red: color.red, green: color.green, blue: color.blue)
    }

    /// The color as `#RRGGBB` in capitals, each channel rounded to the nearest of 256 steps.
    public var hex: String {
        let channels = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }

    public var description: String { hex }

    /// The color `fraction` of the way from `self` to `other`: 0 is `self`, 1 is `other`, clamped in between.
    public func mixed(with other: SpaceTintColor, fraction: Double) -> SpaceTintColor {
        let amount = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        return SpaceTintColor(
            red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount)
    }
}

extension SpaceTintColor {
    /// Hue in degrees (0 up to 360), HSL saturation and HSL lightness, each of the last two from 0 to 1.
    /// A gray has hue 0 and saturation 0.
    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let lightness = (high + low) / 2
        let spread = high - low
        guard spread > 0 else { return (0, 0, lightness) }
        let saturation = spread / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch high {
        case red: hue = (green - blue) / spread
        case green: hue = (blue - red) / spread + 2
        default: hue = (red - green) / spread + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, saturation, lightness)
    }

    /// The color of a hue in degrees, an HSL saturation and an HSL lightness (the last two clamped to 0 to 1).
    public init(hue: Double, saturation: Double, lightness: Double) {
        let s = saturation.isNaN ? 0 : min(max(saturation, 0), 1)
        let l = lightness.isNaN ? 0 : min(max(lightness, 0), 1)
        let h = hue.isNaN ? 0 : hue.truncatingRemainder(dividingBy: 360) + (hue < 0 ? 360 : 0)
        let chroma = (1 - abs(2 * l - 1)) * s
        let x = chroma * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - chroma / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (chroma, x, 0)
        case ..<120: (r, g, b) = (x, chroma, 0)
        case ..<180: (r, g, b) = (0, chroma, x)
        case ..<240: (r, g, b) = (0, x, chroma)
        case ..<300: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        self.init(red: r + m, green: g + m, blue: b + m)
    }

    /// The WCAG relative luminance, 0 for black and 1 for white.
    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two colors, 1 for equal colors up to 21 for black on white.
    public func contrast(with other: SpaceTintColor) -> Double {
        let a = relativeLuminance
        let b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// How a Space's theme tinted the window before `SpacePalette`: the sidebar and the frame around the page are one
/// surface, the window's Frame color, and a theme lays a light wash of its primary color over it, the same in light
/// and dark appearance. The default theme lays none, so a Space nobody themed shows exactly the Frame color.
/// The app still draws this wash until the chrome moves to `SpacePalette` roles; new code uses the palette.
public enum SpaceTint {
    /// How much of the theme's color goes over the Frame color.
    public static let strength = 0.12

    /// The surface color for `theme` over `frame`, the Frame color of the appearance being drawn.
    public static func color(for theme: SpaceTheme, over frame: SpaceTintColor) -> SpaceTintColor {
        guard theme != .default else { return frame }
        return frame.mixed(with: SpaceTintColor(theme.primaryColor), fraction: strength)
    }

    /// One theme color the Space menu offers.
    public struct Preset: Hashable, Sendable {
        public let name: String
        public let theme: SpaceTheme
    }

    /// The colors the Space menu offers besides Default, in menu order: a blue and the brand palette's Jam, Apricot,
    /// Cocoa, Green and Brick.
    public static let presets: [Preset] = [
        ("Blue", "#3B5BDB"), ("Jam", "#E8743B"), ("Apricot", "#FFC08A"), ("Cocoa", "#7A5A48"), ("Green", "#2F7D4F"),
        ("Brick", "#B84E1B"),
    ].map { Preset(name: $0.0, theme: try! SpaceTheme(primaryColorHex: $0.1)) }
}
