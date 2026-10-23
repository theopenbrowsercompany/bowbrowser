import Foundation

// App shortcuts that window features claim before the page sees them (`EngineTabDelegate`'s `handleKeyBeforePage`).
// Each shortcut has its keys here, and `KeyShortcuts.claims` lists which feature claims which shortcut, in one place,
// so two features cannot claim the same key without a test failing. The keys follow Arc's published shortcuts.

/// One key with the modifiers it needs.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable {
        /// A character key, matched against the event's character without modifiers other than Shift, ignoring case.
        case character(String)
        /// A key with no useful character (Tab), matched by its macOS virtual key code.
        case keyCode(Int)
    }

    public var key: Key
    /// Exactly the modifiers that must be held: Shift, Control, Option and Command, no more and no fewer.
    public var modifiers: KeyModifiers

    public init(_ key: Key, _ modifiers: KeyModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func character(_ character: String, _ modifiers: KeyModifiers) -> KeyChord {
        KeyChord(.character(character.lowercased()), modifiers)
    }

    /// Whether `event`, a key down, is this chord. Characters and key ups never match: claiming the key down claims
    /// the whole press.
    public func matches(_ event: EngineKeyEvent) -> Bool {
        guard event.kind == .keyDown, event.modifiers.intersection(Self.matchedModifiers) == modifiers else {
            return false
        }
        switch key {
        case .character(let character):
            return event.charactersIgnoringModifiers.lowercased() == character
        case .keyCode(let code):
            return event.keyCode == code
        }
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "Ctrl+" }
        if modifiers.contains(.option) { text += "Option+" }
        if modifiers.contains(.shift) { text += "Shift+" }
        if modifiers.contains(.command) { text += "Cmd+" }
        switch key {
        case .character(let character): text += character.uppercased()
        case .keyCode(let code): text += code == KeyChord.tabKeyCode ? "Tab" : "key \(code)"
        }
        return text
    }

    static let matchedModifiers: KeyModifiers = [.shift, .control, .option, .command]
    /// The macOS virtual key code of Tab.
    public static let tabKeyCode = 48
}

/// A named app shortcut and its keys.
public enum KeyShortcut: String, CaseIterable, Hashable, Sendable {
    /// Cmd+T: a new tab, or the command bar once it exists.
    case newTab
    /// Cmd+L: change the shown page's address.
    case changeURL
    /// Cmd+Shift+C: copy the shown page's address.
    case copyURL
    /// Cmd+plus (Cmd+= on a US keyboard): zoom in.
    case zoomIn
    /// Cmd+minus: zoom out.
    case zoomOut
    /// Cmd+0: back to 100%.
    case actualSize
    /// Ctrl+Tab: the recent tabs switcher.
    case recentTabs

    /// Every key that triggers the shortcut.
    public var chords: [KeyChord] {
        switch self {
        case .newTab: [.character("t", .command)]
        case .changeURL: [.character("l", .command)]
        case .copyURL: [.character("c", [.command, .shift])]
        case .zoomIn: [.character("=", .command), .character("+", .command), .character("+", [.command, .shift])]
        case .zoomOut: [.character("-", .command)]
        case .actualSize: [.character("0", .command)]
        case .recentTabs: [KeyChord(.keyCode(KeyChord.tabKeyCode), .control)]
        }
    }

    /// Whether `event` is one of this shortcut's keys.
    public func matches(_ event: EngineKeyEvent) -> Bool {
        chords.contains { $0.matches(event) }
    }
}

/// The window features that claim shortcuts. Add a case when a feature starts claiming keys.
public enum KeyShortcutOwner: String, Hashable, Sendable {
    /// The command bar: new tab and change URL.
    case commandBar
    /// The page's toolbar actions: copy URL.
    case toolbar
    /// Page zoom.
    case zoom
    /// The recent tabs switcher.
    case recentTabs
}

/// One feature's claim on one shortcut.
public struct KeyShortcutClaim: Hashable, Sendable {
    public var shortcut: KeyShortcut
    public var owner: KeyShortcutOwner

    public init(_ shortcut: KeyShortcut, _ owner: KeyShortcutOwner) {
        self.shortcut = shortcut
        self.owner = owner
    }
}

/// Two claims that want the same key.
public struct KeyShortcutConflict: Hashable, Sendable, CustomStringConvertible {
    public var chord: KeyChord
    public var claims: [KeyShortcutClaim]

    public var description: String {
        let owners = claims.map { "\($0.owner.rawValue).\($0.shortcut.rawValue)" }
        return "\(chord) is claimed by " + owners.joined(separator: ", ")
    }
}

public enum KeyShortcuts {
    /// Every shortcut a window feature claims before the page, with the feature that claims it. A feature claims a
    /// key only through `shortcut(for:claimedBy:)`, so a key missing here never reaches it. One entry per line.
    public static let claims: [KeyShortcutClaim] = [
        KeyShortcutClaim(.newTab, .commandBar),
        KeyShortcutClaim(.changeURL, .commandBar),
        KeyShortcutClaim(.copyURL, .toolbar),
        KeyShortcutClaim(.zoomIn, .zoom),
        KeyShortcutClaim(.zoomOut, .zoom),
        KeyShortcutClaim(.actualSize, .zoom),
        KeyShortcutClaim(.recentTabs, .recentTabs),
    ]

    /// The shortcut `event` triggers among those `owner` claims in `claims`, or nil. A feature's
    /// `handleKeyBeforePage` answers true exactly when this is not nil and it acts on the shortcut.
    public static func shortcut(
        for event: EngineKeyEvent,
        claimedBy owner: KeyShortcutOwner,
        in claims: [KeyShortcutClaim] = claims
    ) -> KeyShortcut? {
        claims.first { $0.owner == owner && $0.shortcut.matches(event) }?.shortcut
    }

    /// The keys more than one claim wants (the same shortcut claimed twice, or two shortcuts sharing a key), in the
    /// order they first appear. Empty when every key has one owner.
    public static func conflicts(in claims: [KeyShortcutClaim] = claims) -> [KeyShortcutConflict] {
        var byChord: [KeyChord: [KeyShortcutClaim]] = [:]
        var order: [KeyChord] = []
        for claim in claims {
            for chord in claim.shortcut.chords {
                if byChord[chord] == nil { order.append(chord) }
                byChord[chord, default: []].append(claim)
            }
        }
        return order.compactMap { chord in
            let claims = byChord[chord] ?? []
            return claims.count > 1 ? KeyShortcutConflict(chord: chord, claims: claims) : nil
        }
    }
}
