import AppKit
import BowCore

// Engine tabs a test drives directly through the BowCore engine contract, with no window, so it can be their
// delegate and see the engine hooks that the window core answers with their defaults (popup decisions, keys before
// the page). Tests close every probe they open (`E2EEngineProbe.close`); the runner's `e2e.isolation`
// check fails on any left open.

/// One engine tab with no window, its delegate recording what reaches it.
@MainActor
final class E2EEngineProbe: EngineTabDelegate {
    let tab: any EngineTab
    private let devToolsSession: BowDevToolsSession
    /// Every event the tab sent, in order.
    private(set) var events: [TabEvent] = []
    /// HTTP status of every load that finished; a failed load records its negative error code.
    private(set) var loads: [Int] = []

    /// Where popups go; every request is recorded in `popupRequests`.
    var popupDecision: PopupDecision = .block
    private(set) var popupRequests: [PopupRequest] = []
    /// Tabs popups arrived as, wrapped as probes the test must close too.
    private(set) var popupTabs: [E2EEngineProbe] = []
    /// Set once `close` started, so a popup tab arriving late is closed instead of kept.
    private var isClosing = false

    /// Which key events to claim before the page; every one offered is recorded in `keyEvents`.
    var claimsKey: (EngineKeyEvent) -> Bool = { _ in false }
    private(set) var keyEvents: [EngineKeyEvent] = []
    private(set) var claimedKeys: [EngineKeyEvent] = []

    private init(tab: any EngineTab) {
        self.tab = tab
        devToolsSession = BowDevToolsSession(tabID: tab.tabID.rawValue)
        tab.delegate = self
    }

    /// Opens a probe tab on `url` in `profile`, or in a fresh in-memory profile made for it.
    static func open(_ url: URL, in profile: (any EngineProfile)? = nil) throws -> E2EEngineProbe {
        let profile = try profile ?? makeProfile()
        return E2EEngineProbe(tab: profile.createTab(url: url))
    }

    /// A fresh in-memory profile, so nothing a probe stores (zoom, credentials) outlives its test.
    static func makeProfile() throws -> any EngineProfile {
        guard let app = NSApp.delegate as? AppDelegate else { throw E2EError("the app delegate is not Bow's") }
        let id = ProfileID("e2e-engine-\(UUID().uuidString)")
        return try app.engine.createProfile(id: id, isPersistent: false)
    }

    /// Closes the probe's tab and every popup tab it received, and waits until they are closed.
    func close() async {
        isClosing = true
        for popup in popupTabs { await popup.close() }
        if !tab.isClosed { _ = await tab.close() }
        devToolsSession.close()
    }

    /// Waits until `condition` holds, within the running step's wait budget, and throws naming `what` otherwise.
    func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while !condition() {
            if Date() > deadline { throw E2EError("gave up waiting for \(what)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits for load number `count` to finish and returns its status.
    func waitForLoad(_ count: Int) async throws -> Int {
        try await until("load \(count) of \(tab.state.url?.absoluteString ?? "the probe")") { loads.count >= count }
        return loads[count - 1]
    }

    func devTools(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let response = try await withCheckedThrowingContinuation { continuation in
            devToolsSession.callMethod(method, params: params) { result, error in
                if let result {
                    continuation.resume(returning: ProbeResult(value: result))
                } else {
                    continuation.resume(throwing: E2EError("\(method): \(error?.localizedDescription ?? "no result")"))
                }
            }
        }
        return response.value
    }

    /// Evaluates `expression` in the page and returns its value; `userGesture` runs it as if a person had clicked.
    func evaluate(_ expression: String, userGesture: Bool = false) async throws -> Any? {
        let result = try await devTools(
            "Runtime.evaluate",
            ["expression": expression, "returnByValue": true, "awaitPromise": true, "userGesture": userGesture])
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw E2EError("\(expression) threw: \(exception["text"] ?? "an exception")")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// Presses and releases a character key, with Command when `command` is true.
    func pressKey(_ character: String, keyCode: Int, macKeyCode: Int, command: Bool = false) async throws {
        _ = try await devTools("Emulation.setFocusEmulationEnabled", ["enabled": true])
        var down: [String: Any] = [
            "type": "keyDown", "key": character, "code": "Key\(character.uppercased())",
            "windowsVirtualKeyCode": keyCode, "nativeVirtualKeyCode": macKeyCode, "modifiers": command ? 4 : 0,
        ]
        if !command { down["text"] = character }
        var up = down
        up["type"] = "keyUp"
        up["text"] = nil
        _ = try await devTools("Input.dispatchKeyEvent", down)
        _ = try await devTools("Input.dispatchKeyEvent", up)
    }

    // MARK: EngineTabDelegate

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        events.append(event)
        switch event {
        case .didFinish(_, let status): loads.append(status)
        case .didFail(_, let error) where !error.isAborted: loads.append(-abs(error.code))
        case .closed, .unloaded: devToolsSession.close()
        default: break
        }
    }

    func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision {
        popupRequests.append(request)
        return popupDecision
    }

    func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest) {
        guard !isClosing else {
            Task { _ = await newTab.close() }
            return
        }
        popupTabs.append(E2EEngineProbe(tab: newTab))
    }

    func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool {
        keyEvents.append(event)
        guard claimsKey(event) else { return false }
        claimedKeys.append(event)
        return true
    }
}

private struct ProbeResult: @unchecked Sendable {
    let value: [String: Any]
}
