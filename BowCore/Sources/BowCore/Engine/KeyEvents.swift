import Foundation

// Key presses the app sees before the page does, so app shortcuts (Cmd+L, Cmd+Shift+C) win over the page.

/// Modifier keys held during a key event.
public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// A key event on its way to the page.
public struct EngineKeyEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case keyDown
        case keyUp
        /// The character a key down produced.
        case character
    }

    public var kind: Kind
    /// The macOS virtual key code.
    public var keyCode: Int
    /// The character the key produced with its modifiers, empty when none.
    public var characters: String
    /// The character without modifiers other than Shift, for matching shortcuts.
    public var charactersIgnoringModifiers: String
    public var modifiers: KeyModifiers
    /// True when focus is in an editable field of the page.
    public var isInEditableField: Bool

    public init(
        kind: Kind,
        keyCode: Int,
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: KeyModifiers = [],
        isInEditableField: Bool = false
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.isInEditableField = isInEditableField
    }
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool {
        false
    }
}
