import Foundation

/// Why an icon or color was refused. The Space is left as it was.
public enum SpaceAppearanceError: Error, Equatable, CustomStringConvertible {
    /// An emoji icon must be exactly one emoji (one grapheme).
    case invalidEmoji(String)
    /// A symbol name is lowercase letters, digits, dots, dashes and underscores, starting with a letter.
    case invalidSymbolName(String)
    /// A color is a hex value: `#RRGGBB`, or `#RGB` as a short form, with or without the `#`.
    case invalidColor(String)

    public var description: String {
        switch self {
        case .invalidEmoji(let text): return "\"\(text)\" is not a single emoji"
        case .invalidSymbolName(let text): return "\"\(text)\" is not a symbol name"
        case .invalidColor(let text): return "\"\(text)\" is not a hex color"
        }
    }
}

/// The picture shown next to a Space's name: one emoji or the name of a symbol. A value can only be made valid, from
/// code or from a saved file, so a store never holds a bad one. A Space with no icon shows none.
public struct SpaceIcon: Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case emoji
        case symbol
    }

    public let kind: Kind
    /// The emoji itself, or the symbol's name.
    public let value: String

    /// An emoji icon. `text` is trimmed and must be exactly one emoji: a flag, a skin toned hand or a ZWJ sequence
    /// counts as one; digits, letters and two emoji do not.
    public init(emoji text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first, Self.isEmoji(character) else {
            throw SpaceAppearanceError.invalidEmoji(text)
        }
        kind = .emoji
        value = trimmed
    }

    /// A named symbol icon, such as `heart` or `bolt`. `name` is trimmed, 1 to 64 characters, starting with a
    /// lowercase letter and then lowercase letters, digits, `.`, `-` or `_`.
    public init(symbol name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSymbolName(trimmed) else { throw SpaceAppearanceError.invalidSymbolName(name) }
        kind = .symbol
        value = trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case kind, value
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let value = try values.decode(String.self, forKey: .value)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .emoji: try self.init(emoji: value)
        case .symbol: try self.init(symbol: value)
        }
    }

    private static func isSymbolName(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count), let first = text.unicodeScalars.first,
            ("a"..."z").contains(first)
        else { return false }
        return text.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    /// Whether one grapheme is drawn as an emoji. A bare digit, `#` or `©` has the emoji property but is text; it
    /// counts only as part of a keycap (`1️⃣`) or with the emoji variation selector (`©️`, `❤️`).
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return first.properties.isEmoji && scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
    }
}

/// A color as a hex value, kept as `#RRGGBB` in capitals so equal colors compare equal and save the same way.
public struct SpaceColor: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The color as `#RRGGBB`.
    public let hex: String
    /// The channels from 0 to 1, for drawing.
    public let red: Double
    public let green: Double
    public let blue: Double

    /// Reads `#RRGGBB`, `RRGGBB` or the short form `#RGB`, in any case, after trimming. Transparency is not part of a
    /// theme color: the app decides how strongly to tint.
    public init(hex text: String) throws {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 3 || digits.count == 6, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw SpaceAppearanceError.invalidColor(text)
        }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(digits, radix: 16) else { throw SpaceAppearanceError.invalidColor(text) }
        hex = "#" + digits.uppercased()
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    public init(from decoder: any Decoder) throws {
        try self.init(hex: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var description: String { hex }
}

/// The look a Space gives the window. Today that is one primary color, which the app tints the sidebar and window
/// background with. Arc's richer themes (a second color for a gradient, a style, a forced light or dark appearance)
/// will be further optional fields of this object, so files and builds without them keep working.
public struct SpaceTheme: Hashable, Sendable, Codable {
    /// The theme a Space has until the person picks one: a neutral gray blue.
    public static let `default` = SpaceTheme(primaryColor: try! SpaceColor(hex: "#8E96A8"))

    public let primaryColor: SpaceColor

    public init(primaryColor: SpaceColor) { self.primaryColor = primaryColor }

    /// A theme from a hex color such as `#3B5BDB`.
    public init(primaryColorHex hex: String) throws { self.init(primaryColor: try SpaceColor(hex: hex)) }
}

extension SidebarSpace {
    /// The theme to draw: the Space's own, or the default one when the person has not chosen.
    public var resolvedTheme: SpaceTheme { theme ?? .default }
}

extension SidebarGraph {
    /// The theme of the Space on screen, for the app to tint the sidebar and window background with.
    public var activeTheme: SpaceTheme { activeSpace?.resolvedTheme ?? .default }
}

extension SidebarStore {
    /// Sets a Space's icon, or removes it with nil.
    public func setSpaceIcon(_ id: SidebarSpaceID, to icon: SpaceIcon?) throws {
        try transaction { try mutate(.setSpaceIcon(id, icon)) }
    }

    /// Sets a Space's icon to one emoji. Throws `SpaceAppearanceError.invalidEmoji` for anything else.
    public func setSpaceIcon(_ id: SidebarSpaceID, emoji: String) throws {
        try setSpaceIcon(id, to: try SpaceIcon(emoji: emoji))
    }

    /// Sets a Space's icon to a named symbol. Throws `SpaceAppearanceError.invalidSymbolName` for a bad name.
    public func setSpaceIcon(_ id: SidebarSpaceID, symbol: String) throws {
        try setSpaceIcon(id, to: try SpaceIcon(symbol: symbol))
    }

    /// Sets a Space's theme, or goes back to the default theme with nil.
    public func setSpaceTheme(_ id: SidebarSpaceID, to theme: SpaceTheme?) throws {
        try transaction { try mutate(.setSpaceTheme(id, theme)) }
    }

    /// Sets a Space's primary color from a hex value. Throws `SpaceAppearanceError.invalidColor` for a bad one.
    public func setSpaceTheme(_ id: SidebarSpaceID, primaryColorHex hex: String) throws {
        try setSpaceTheme(id, to: try SpaceTheme(primaryColorHex: hex))
    }
}
