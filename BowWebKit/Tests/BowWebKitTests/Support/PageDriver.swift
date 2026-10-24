import AppKit
import WebKit

@testable import BowWebKit

/// Drives one web view the way a person would and reads its page. Page reads run with `callAsyncJavaScript` in a
/// named test content world, with arguments passed as values, never spliced into the source, so the page's own
/// scripts cannot see or break them. Input is real `NSEvent`s sent to the web view's own off screen window, so the
/// page sees trusted events and no Accessibility permission is needed.
@MainActor
final class PageDriver {
    static let world = WKContentWorld.world(name: "BowWebKitTest")
    private static var eventNumber = 100

    let webView: WKWebView

    init(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: Page reads

    /// Runs `body` as an async function in the test world and returns its result as JSON values (NSNull for
    /// undefined or null).
    func eval(_ body: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil) async throws -> Any {
        let wrapped =
            "const __r = await (async () => { \(body) })(); return JSON.stringify(__r === undefined ? null : __r);"
        let text: String = try await withCheckedThrowingContinuation { done in
            webView.callAsyncJavaScript(wrapped, arguments: arguments, in: frame, in: Self.world) { result in
                switch result {
                case .success(let value): done.resume(returning: (value as? String) ?? "null")
                case .failure(let error): done.resume(throwing: error)
                }
            }
        }
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    func string(_ body: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil) async throws -> String {
        (try await eval(body, arguments, in: frame) as? String) ?? ""
    }

    func number(_ body: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil) async throws -> Double {
        (try await eval(body, arguments, in: frame) as? NSNumber)?.doubleValue ?? .nan
    }

    func bool(_ body: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil) async throws -> Bool {
        (try await eval(body, arguments, in: frame) as? Bool) ?? false
    }

    /// Waits until the page at `url` has a complete document.
    func waitForLoad(of url: URL, timeout: Double = 10) async throws {
        try await waitUntil("load of \(url.absoluteString)", timeout: timeout) {
            guard webView.url == url, !webView.isLoading else { return false }
            return try await string("return document.readyState") == "complete"
        }
    }

    /// Loads `url` straight into the web view and waits for it; for tests of the host itself, since a tab test
    /// loads through the tab.
    func load(_ url: URL, timeout: Double = 10) async throws {
        webView.load(URLRequest(url: url))
        try await waitForLoad(of: url, timeout: timeout)
    }

    /// The centre of the element `selector` in page (CSS) coordinates, scrolled into view first.
    func centre(of selector: String, in frame: WKFrameInfo? = nil) async throws -> CGPoint {
        let value = try await eval(
            """
            const e = document.querySelector(selector);
            if (!e) return null;
            e.scrollIntoView({ block: "center", inline: "center" });
            const r = e.getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
            """, ["selector": selector], in: frame)
        guard let pair = value as? [NSNumber], pair.count == 2 else { throw TestError("no element \(selector)") }
        return CGPoint(x: pair[0].doubleValue, y: pair[1].doubleValue)
    }

    // MARK: Input

    private var window: NSWindow {
        get throws {
            guard let window = webView.window else { throw TestError("the web view is in no window") }
            return window
        }
    }

    /// A page point (CSS pixels from the top left of the viewport) in window coordinates.
    func windowPoint(_ point: CGPoint) -> NSPoint {
        let local = webView.isFlipped ? point : NSPoint(x: point.x, y: webView.bounds.height - point.y)
        return webView.convert(local, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int) throws -> NSEvent {
        Self.eventNumber += 1
        guard
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: try window.windowNumber, context: nil, eventNumber: Self.eventNumber, clickCount: clicks,
                pressure: type == .leftMouseUp || type == .mouseMoved ? 0 : 1)
        else { throw TestError("could not make a \(type) event") }
        return event
    }

    /// A left click at `point` (page coordinates), as a real mouse move, down and up; returns once WebKit has
    /// handled them (or at once when that private wait is absent, so the caller then polls the page).
    func click(_ point: CGPoint) async throws {
        let at = windowPoint(point)
        let window = try window
        window.sendEvent(try mouse(.mouseMoved, at, clicks: 0))
        window.sendEvent(try mouse(.leftMouseDown, at, clicks: 1))
        window.sendEvent(try mouse(.leftMouseUp, at, clicks: 1))
        _ = await WebKitSPI.afterPendingMouseEvents(webView)
    }

    func click(_ selector: String, in frame: WKFrameInfo? = nil) async throws {
        try await click(try await centre(of: selector, in: frame))
    }

    /// One key press with `modifiers`, sent through `NSApp.sendEvent` so menu shortcuts see it first, as a real key
    /// does.
    func key(
        _ code: UInt16, characters: String, ignoringModifiers: String? = nil, modifiers: NSEvent.ModifierFlags = []
    ) throws {
        let window = try window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            Self.eventNumber += 1
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters,
                    isARepeat: false, keyCode: code)
            else { throw TestError("could not make a key event") }
            NSApp.sendEvent(event)
        }
    }

    /// Types `text` as key down and up events, one character at a time.
    func type(_ text: String) throws {
        for character in text {
            let chars = String(character)
            guard let code = KeyCodes.code(for: character) else { throw TestError("no key code for \(chars)") }
            try key(
                code, characters: chars, ignoringModifiers: chars.lowercased(),
                modifiers: character.isUppercase ? .shift : [])
        }
    }
}

/// US keyboard virtual key codes for the characters the tests type.
enum KeyCodes {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
        "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
        "-": 27, ".": 47, ",": 43,
    ]

    static func code(for character: Character) -> UInt16? {
        letters[Character(character.lowercased())]
    }
}
