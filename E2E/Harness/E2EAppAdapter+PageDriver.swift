import AppKit

// The page driver (`E2EPage`'s evaluate, screenshot, focus, input and crash calls) over Chromium's DevTools protocol:
// the only harness code that knows the protocol's methods, so another engine's adapter replaces this one file.

extension E2ETabPage {
    func evaluate(_ expression: String, arguments: [String: Any], userGesture: Bool) async throws -> Any? {
        var params: [String: Any] = [
            "expression": try Self.bind(arguments, in: expression), "returnByValue": true, "awaitPromise": true,
        ]
        if userGesture { params["userGesture"] = true }
        let response = try await devTools("Runtime.evaluate", params)
        if let details = response["exceptionDetails"] as? [String: Any] {
            let exception = details["exception"] as? [String: Any]
            let text = exception?["description"] as? String ?? details["text"] as? String ?? "exception"
            throw E2EError("\(expression) threw: \(text)")
        }
        return (response["result"] as? [String: Any])?["value"]
    }

    func screenshot() async throws -> NSImage {
        let response = try await devTools("Page.captureScreenshot", ["format": "png"], readOnly: true)
        guard let base64 = response["data"] as? String, let data = Data(base64Encoded: base64),
            let image = NSImage(data: data)
        else {
            throw E2EError("Page.captureScreenshot returned no image")
        }
        return image
    }

    func emulateFocus() async throws {
        _ = try await devTools("Emulation.setFocusEmulationEnabled", ["enabled": true])
    }

    func dispatchMouse(_ event: E2EMouseEvent) async throws {
        var params: [String: Any] = ["x": event.x, "y": event.y]
        switch event.kind {
        case .press, .release:
            // `buttons` is the buttons held after the event: the pressed one while held, none once released.
            params["type"] = event.kind == .press ? "mousePressed" : "mouseReleased"
            params["button"] = event.button.rawValue
            params["buttons"] = event.kind == .press ? Self.heldBit(event.button) : 0
            params["clickCount"] = 1
            params["modifiers"] = event.modifiers.rawValue
        case .move:
            params["type"] = "mouseMoved"
            params["button"] = "none"
            params["buttons"] = 0
        }
        _ = try await devTools("Input.dispatchMouseEvent", params)
    }

    func dispatchKey(_ event: E2EKeyEvent) async throws {
        // A key down that types text is Chromium's keyDown (which also sends the character); one that types none is
        // its rawKeyDown.
        var params: [String: Any] = [
            "type": event.isDown ? (event.text == nil ? "rawKeyDown" : "keyDown") : "keyUp",
            "key": event.key, "code": event.code,
            "windowsVirtualKeyCode": Self.windowsKeyCode(event.key),
            "nativeVirtualKeyCode": event.macKeyCode, "modifiers": event.modifiers.rawValue,
        ]
        if event.isDown, let text = event.text { params["text"] = text }
        if let unmodified = event.unmodifiedText { params["unmodifiedText"] = unmodified }
        _ = try await devTools("Input.dispatchKeyEvent", params)
    }

    func insertText(_ text: String) async throws {
        _ = try await devTools("Input.insertText", ["text": text])
    }

    func crash() throws {
        try requireActive("crash the page")
        // The call never answers once the renderer is gone, so it is not waited for.
        Task { _ = try? await self.devTools("Page.crash", [:]) }
    }

    /// The Input.dispatchMouseEvent `buttons` bit for `button` while it is held.
    private static func heldBit(_ button: E2EMouseButton) -> Int {
        switch button {
        case .left: 1
        case .right: 2
        case .middle: 4
        }
    }

    /// The Windows virtual key code Chromium reads for a DOM `key`: the named keys' own codes, and a character's
    /// upper case code point otherwise (the letters' VK_A to VK_Z).
    static func windowsKeyCode(_ key: String) -> Int {
        switch key {
        case "Enter": 13
        case "Tab": 9
        case "Backspace": 8
        case "Escape": 27
        default: Int(key.uppercased().unicodeScalars.first?.value ?? 0)
        }
    }

    /// `expression` with each of `arguments` bound to a constant of its name, as an arrow function called with the
    /// arguments as JSON; `expression` itself when there are none.
    private static func bind(_ arguments: [String: Any], in expression: String) throws -> String {
        guard !arguments.isEmpty else { return expression }
        let names = arguments.keys.sorted()
        for name in names where name.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) == nil {
            throw E2EError("\(name) is not a JavaScript identifier")
        }
        let values = try names.map { name -> String in
            guard let value = arguments[name], JSONSerialization.isValidJSONObject([value]),
                let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                let json = String(data: data, encoding: .utf8)
            else { throw E2EError("argument \(name) is not a JSON value") }
            return json
        }
        return "((\(names.joined(separator: ", "))) => (\n\(expression)\n))(\(values.joined(separator: ", ")))"
    }
}
