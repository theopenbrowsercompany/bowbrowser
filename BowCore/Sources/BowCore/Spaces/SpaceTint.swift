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

/// How a Space's theme tints the window: the sidebar and the frame around the page are one surface, the window's
/// Frame color, and a theme lays a light wash of its primary color over it, the same in light and dark appearance.
/// The default theme lays none, so a Space nobody themed shows exactly the Frame color.
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
