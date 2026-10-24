import Foundation

// Input inside web pages, sent through the page driver's input events (`E2EPage.dispatchMouse`, `dispatchKey`,
// `insertText`): it needs no window focus or accessibility permission, and the engine treats it as real user input
// (it grants user activation, which a beforeunload prompt needs). App shortcuts are not page input: tests trigger
// them through the app's menu, never through the page driver.

/// A key `E2EPage.press(_:)` can send.
enum E2EKey {
    case enter
    case tab
    case backspace
    case escape

    /// The key's DOM `key` and `code` values, its macOS virtual key code (kVK_*), and the text it types.
    fileprivate var event: (key: String, code: String, macKeyCode: Int, text: String?) {
        switch self {
        case .enter: ("Enter", "Enter", 36, "\r")
        case .tab: ("Tab", "Tab", 48, nil)
        case .backspace: ("Backspace", "Backspace", 51, nil)
        case .escape: ("Escape", "Escape", 53, nil)
        }
    }
}

/// A mouse button a page press can use: `E2EPage.click(_:button:modifiers:)` presses the left or middle one, and
/// `E2EPage.rightClick(_:)` the right one.
enum E2EMouseButton: String {
    case left
    case middle
    case right
}

/// One mouse event for `E2EPage.dispatchMouse`, at a point in the page's viewport (CSS pixels from its top left).
struct E2EMouseEvent {
    enum Kind {
        /// `button` goes down, and stays held until its release.
        case press
        /// `button` comes up, leaving no button held.
        case release
        /// The pointer moves with no button held (`button` is ignored).
        case move
    }

    var kind: Kind
    var x: Double
    var y: Double
    var button: E2EMouseButton = .left
    var modifiers: E2EInputModifiers = []
}

/// One key event for `E2EPage.dispatchKey`: a key going down or coming up in the page's focused element.
struct E2EKeyEvent {
    /// True for the key going down, false for it coming up.
    var isDown: Bool
    /// The DOM `key` value ("Enter", "j").
    var key: String
    /// The DOM `code` value ("Enter", "KeyJ").
    var code: String
    /// The macOS virtual key code (kVK_*), which app shortcuts match on.
    var macKeyCode: Int
    /// The text a key down types, nil for a key that types none (or one whose modifiers make it a shortcut).
    var text: String? = nil
    /// The characters the key carries without modifiers, which shortcuts match on; nil to leave them out.
    var unmodifiedText: String? = nil
    var modifiers: E2EInputModifiers = []
}

/// Where a page press lands, in the page's viewport, whether the page itself can confirm that it arrived, and the
/// verb its errors and resend notes use ("click", "right click").
struct E2EPressTarget {
    var selector: String
    var verb: String
    var x: Double
    var y: Double
    var confirms: Bool
}

/// Modifier keys held during a page mouse or key event.
struct E2EInputModifiers: OptionSet {
    let rawValue: Int
    static let option = E2EInputModifiers(rawValue: 1)
    static let control = E2EInputModifiers(rawValue: 2)
    static let command = E2EInputModifiers(rawValue: 4)
    static let shift = E2EInputModifiers(rawValue: 8)
}

extension E2EPage {
    /// Clicks the center of the first element matching `selector` with `button` (the left one by default) while
    /// `modifiers` are held, scrolling it into view first. The keys count as held for this click only, so a Cmd-click
    /// on a link opens it the way Chromium opens a modified click. Throws when no element matches, it has no size, or
    /// something else covers its center (so the click would land elsewhere).
    ///
    /// Chromium's renderer drops every input but moves while a page's main frame updates are deferred or its
    /// commits are held for its first contentful paint (WidgetInputHandlerManager), and the DevTools call still
    /// succeeds, so under load a click right after a load can vanish with no error. The click is therefore confirmed:
    /// capturing `pointerdown` and `click` listeners record what reached the page, and a press or click the page never saw is sent again, a short moment later, until it
    /// lands or the step's wait budget runs out. Each resend is logged to stderr (chromium.log). A click into a
    /// frame is not confirmed, since the frame's own document receives it. Any button and modifiers
    /// are confirmed and resent alike: a click of another button than the left one reaches the page as `auxclick`,
    /// which counts as the click.
    func click(_ selector: String, button: E2EMouseButton = .left, modifiers: E2EInputModifiers = []) async throws {
        let target = try await pressTarget(selector, verb: "click")
        try await confirmedPress(at: target, button: button, modifiers: modifiers, arriving: ["click", "auxclick"])
    }

    /// Where a press on the first element matching `selector` lands, scrolling it into view first, and whether the
    /// page itself can confirm it (not when it lands in a frame, whose own document receives it). Turns focus
    /// emulation on first. Throws when no element matches, it has no size, or something else covers its center (so
    /// the press would land elsewhere).
    func pressTarget(_ selector: String, verb: String) async throws -> E2EPressTarget {
        try await emulateFocus()
        let center = try await evaluate(
            """
            (() => {
              const element = document.querySelector(selector);
              if (!element) return 'no element matches';
              element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              const rect = element.getBoundingClientRect();
              if (rect.width === 0 || rect.height === 0) return 'the element has no size';
              const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
              const hit = document.elementFromPoint(x, y);
              if (!element.contains(hit)) return 'another element covers its center';
              return [x, y, ['IFRAME', 'FRAME', 'EMBED', 'OBJECT'].includes(hit.tagName) ? 0 : 1];
            })()
            """,
            arguments: ["selector": selector], userGesture: false
        )
        guard let point = center as? [Double], point.count == 3 else {
            throw E2EError("cannot \(verb) \(selector): \(center as? String ?? "no position")")
        }
        return E2EPressTarget(selector: selector, verb: verb, x: point[0], y: point[1], confirms: point[2] == 1)
    }

    /// Presses and releases `button` at `target` with `modifiers` held, and confirms that one of `arriving` (the
    /// event the press and release exist for: `click`, `contextmenu`) reached the page; when it did not, the press
    /// and release are sent again, a short moment later, until it lands or the step's wait budget runs out (see
    /// `click(_:button:modifiers:)` for why). Every press is followed by its release, so no button stays held. Once
    /// the page saw one of `arriving`, nothing is sent again, so a press whose default action opens something (a
    /// context menu) opens it once. Each resend is logged to stderr (chromium.log) as `E2E <verb> <selector>: ...`,
    /// naming whether the page missed the press (`pointerdown`) or only the event. A target that cannot confirm is
    /// pressed once.
    func confirmedPress(
        at target: E2EPressTarget, button: E2EMouseButton, modifiers: E2EInputModifiers, arriving: [String]
    ) async throws {
        func send(_ kind: E2EMouseEvent.Kind) async throws {
            try await dispatchMouse(
                E2EMouseEvent(kind: kind, x: target.x, y: target.y, button: button, modifiers: modifiers))
        }
        // Whether the page saw `field` since it was armed. The driver returns once the page handled the event, so
        // its listener has run by then. No record at all means a new document replaced the page,
        // which only input that landed can do, so that counts as seen.
        func missed(_ field: String) async throws -> Bool {
            try await evaluate("window.\(Self.pressRecord)?.\(field)") as? Bool == false
        }
        let arm = Self.armPressRecord(arriving: arriving)
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        var resends = 0
        while true {
            if target.confirms { _ = try await evaluate(arm) }
            try await send(.press)
            let pressLost = target.confirms ? try await missed("pressed") : false
            try await send(.release)
            // Only the event decides: when it arrived, nothing is sent again, even if `pointerdown` went unseen.
            guard target.confirms, try await missed("arrived") else { return }
            let lost = pressLost ? "press" : arriving[0]
            resends += 1
            let note = "E2E \(target.verb) \(target.selector): the page missed the \(lost), resend \(resends)\n"
            FileHandle.standardError.write(Data(note.utf8))
            guard Date() < deadline else {
                throw E2EError(
                    "cannot \(target.verb) \(target.selector): the page missed the \(lost) \(resends) times")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Moves the pointer, with no button held, to the center of the first element matching `selector`, scrolling it
    /// into view first, as a person hovering it does. Confirmed like a press: a `mousemove` listener records that
    /// the move reached the page, and a move the page never saw is sent again, a short moment later, until it lands
    /// or the step's wait budget runs out (each resend logged to stderr). A move into a frame is sent once. Throws as
    /// `pressTarget(_:verb:)` does.
    func movePointer(to selector: String) async throws {
        let target = try await pressTarget(selector, verb: "move the pointer to")
        let arm = Self.armPressRecord(arriving: ["mousemove"])
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        var resends = 0
        while true {
            if target.confirms { _ = try await evaluate(arm) }
            try await dispatchMouse(E2EMouseEvent(kind: .move, x: target.x, y: target.y))
            guard target.confirms, try await evaluate("window.\(Self.pressRecord)?.arrived") as? Bool == false
            else { return }
            resends += 1
            let note = "E2E \(target.verb) \(selector): the page missed the move, resend \(resends)\n"
            FileHandle.standardError.write(Data(note.utf8))
            guard Date() < deadline else {
                throw E2EError("cannot \(target.verb) \(selector): the page missed the move \(resends) times")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The page global in which `confirmedPress` records whether the press and the event it waits for reached the
    /// page.
    private static var pressRecord: String { "__bowE2EPress" }

    /// Starts a fresh record for one press and the first of `arriving` to follow it, removing the listeners of the
    /// previous record so resends do not pile them up.
    private static func armPressRecord(arriving: [String]) -> String {
        """
        (() => {
          window.\(pressRecord)?.listeners.abort();
          const record = window.\(pressRecord) = {
            pressed: false, arrived: false, listeners: new AbortController(),
          };
          const options = { capture: true, once: true, signal: record.listeners.signal };
          addEventListener('pointerdown', () => { record.pressed = true; }, options);
          for (const type of \(jsArray(arriving))) {
            addEventListener(type, () => { record.arrived = true; }, options);
          }
        })()
        """
    }

    /// Types `text` into the focused element, the way text arrives from a keyboard or an input method.
    func type(_ text: String) async throws {
        try await emulateFocus()
        try await insertText(text)
    }

    /// Presses and releases `key` in the focused element.
    func press(_ key: E2EKey) async throws {
        try await emulateFocus()
        let event = key.event
        let down = E2EKeyEvent(
            isDown: true, key: event.key, code: event.code, macKeyCode: event.macKeyCode, text: event.text)
        var up = down
        up.isDown = false
        up.text = nil
        try await dispatchKey(down)
        try await dispatchKey(up)
    }

    /// Presses and releases the letter key `letter` with `modifiers` held, as a keyboard shortcut arrives at the
    /// page. The app claims its own shortcuts before the page sees them; this sends one to check that it does.
    /// `macKeyCode` is the letter's macOS virtual key code (kVK_ANSI_*).
    func press(letter: Character, macKeyCode: Int, modifiers: E2EKeyModifiers) async throws {
        try await emulateFocus()
        let key = String(letter).lowercased()
        var held: E2EInputModifiers = []
        if modifiers.contains(.option) { held.insert(.option) }
        if modifiers.contains(.control) { held.insert(.control) }
        if modifiers.contains(.command) { held.insert(.command) }
        if modifiers.contains(.shift) { held.insert(.shift) }
        // What a real key press carries as its characters without modifiers, which shortcuts match on.
        var down = E2EKeyEvent(
            isDown: true, key: key, code: "Key\(key.uppercased())", macKeyCode: macKeyCode, unmodifiedText: key,
            modifiers: held)
        var up = down
        up.isDown = false
        if modifiers.isEmpty || modifiers == .shift {
            down.text = modifiers == .shift ? key.uppercased() : key
        }
        try await dispatchKey(down)
        try await dispatchKey(up)
    }

    /// `values` as a JavaScript array of string literals.
    static func jsArray(_ values: [String]) -> String {
        "[" + values.map(jsString).joined(separator: ", ") + "]"
    }

    /// `value` as a JavaScript string literal.
    static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
