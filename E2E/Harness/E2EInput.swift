import Foundation

// Input inside web pages, sent through the DevTools Input domain: it needs no window focus or accessibility
// permission, and Chromium treats it as real user input (it grants user activation, which a beforeunload prompt
// needs). App shortcuts are not page input: tests trigger them through the app's menu, never through DevTools.

/// A key `E2EPage.press(_:)` can send.
enum E2EKey {
    case enter
    case tab
    case backspace

    /// The Input.dispatchKeyEvent fields for this key: the Windows key code Chromium uses everywhere, and the
    /// macOS one (kVK_*) it reads as the native code.
    fileprivate var event: (key: String, code: String, keyCode: Int, macKeyCode: Int, text: String?) {
        switch self {
        case .enter: ("Enter", "Enter", 13, 36, "\r")
        case .tab: ("Tab", "Tab", 9, 48, nil)
        case .backspace: ("Backspace", "Backspace", 8, 51, nil)
        }
    }
}

extension E2EPage {
    /// Makes the page behave as if its window were focused. An e2e window never becomes key, so without this
    /// the page has no focus: `document.hasFocus()` is false and focus events do not fire.
    /// The input helpers call it themselves, so tests need not.
    func emulateFocus() async throws {
        _ = try await devTools("Emulation.setFocusEmulationEnabled", ["enabled": true])
    }

    /// Clicks the center of the first element matching `selector` with the left mouse button,
    /// scrolling it into view first. Throws when no element matches, it has no size, or something else covers
    /// its center (so the click would land elsewhere).
    func click(_ selector: String) async throws {
        try await emulateFocus()
        let center = try await evaluate(
            """
            (() => {
              const element = document.querySelector(\(Self.jsString(selector)));
              if (!element) return 'no element matches';
              element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
              const rect = element.getBoundingClientRect();
              if (rect.width === 0 || rect.height === 0) return 'the element has no size';
              const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
              if (!element.contains(document.elementFromPoint(x, y))) return 'another element covers its center';
              return [x, y];
            })()
            """
        )
        guard let point = center as? [Double], point.count == 2 else {
            throw E2EError("cannot click \(selector): \(center as? String ?? "no position")")
        }
        // `buttons` is the buttons held after the event: the left one while pressed, none once released.
        for (type, buttons) in [("mousePressed", 1), ("mouseReleased", 0)] {
            _ = try await devTools(
                "Input.dispatchMouseEvent",
                ["type": type, "x": point[0], "y": point[1], "button": "left", "buttons": buttons, "clickCount": 1]
            )
        }
    }

    /// Types `text` into the focused element, the way text arrives from a keyboard or an input method.
    func type(_ text: String) async throws {
        try await emulateFocus()
        _ = try await devTools("Input.insertText", ["text": text])
    }

    /// Presses and releases `key` in the focused element.
    func press(_ key: E2EKey) async throws {
        try await emulateFocus()
        let event = key.event
        var down: [String: Any] = [
            "key": event.key, "code": event.code,
            "windowsVirtualKeyCode": event.keyCode, "nativeVirtualKeyCode": event.macKeyCode,
        ]
        var up = down
        up["type"] = "keyUp"
        if let text = event.text {
            down["type"] = "keyDown"
            down["text"] = text
        } else {
            down["type"] = "rawKeyDown"
        }
        _ = try await devTools("Input.dispatchKeyEvent", down)
        _ = try await devTools("Input.dispatchKeyEvent", up)
    }

    /// `value` as a JavaScript string literal.
    static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
