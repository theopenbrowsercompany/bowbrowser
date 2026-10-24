import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// A tab delegate that claims the keys `claims` matches, recording every key it was asked about.
@MainActor
final class KeyRecordingDelegate: EngineTabDelegate {
    private(set) var asked: [EngineKeyEvent] = []
    var claims: (EngineKeyEvent) -> Bool = { _ in false }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {}

    func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool {
        asked.append(event)
        return claims(event)
    }

    func reset() { asked = [] }
}

/// What the keys page's own listeners saw, from the DOM the page mirrors them into.
@MainActor
private func pageKeys(_ driver: PageDriver) async throws -> [String] {
    let text = try await driver.string("return document.getElementById('keys').textContent")
    return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String]) ?? []
}

/// The tab's delegate sees each key before the page: a key it claims (Command T) never reaches the page's listeners,
/// key up included, and a key it leaves does, asked about once per press.
///
/// A page gets keys only while its window is key, and Swift Testing runs suites side by side, so a test that takes
/// key runs in `HostTests`, the one serialized suite whose tests take key (`TestHost.show`); in a suite of its own it
/// would take key from a host test's window between its focus checks.
extension HostTests {
    @Test func aClaimedKeyNeverReachesThePageAndAnUnclaimedOneDoes() async throws {
        let rig = try TabRig()
        let page = rig.url("/keys/index.html")
        let tab = rig.tab("/keys/index.html")
        let delegate = KeyRecordingDelegate()
        delegate.claims = { KeyShortcuts.shortcut(for: $0, claimedBy: .commandBar) == .newTab }
        tab.delegate = delegate
        // The web view and its driver live only in this block, before the tab's page is checked released.
        do {
            let webView = try #require(tab.webView)
            let driver = PageDriver(webView)
            try await driver.waitForLoad(of: page)
            // The page has keyboard focus, as when the person clicked into it: its window is the key one and the web
            // view its first responder.
            TestHost.show(rig.surface, in: rig.window)
            rig.surface.focusShownTab()
            #expect(rig.window.firstResponder === webView)
            try await waitUntil("the page has focus", timeout: 5) {
                try await driver.bool("return document.hasFocus()")
            }

            // Command T: the delegate claims it, so the page sees neither its key down nor its key up.
            try driver.key(KeyCodes.code(for: "t")!, characters: "t", modifiers: .command)
            // An unclaimed key after it: once the page saw it, the claimed key would have arrived before it.
            try driver.key(KeyCodes.code(for: "k")!, characters: "k")
            let keys = try await waitFor("the page saw k down and up", timeout: 5) { () -> [String]? in
                let keys = try await pageKeys(driver)
                return keys.contains("keydown k") && keys.contains("keyup k") ? keys : nil
            }
            #expect(keys == ["keydown k", "keyup k"], "the page saw \(keys)")
            // Asked about Command T's key down once (its key up was claimed with it) and about k's key down and up.
            let asked = delegate.asked.map {
                "\($0.kind) \($0.modifiers.contains(.command) ? "cmd+" : "")\($0.characters)"
            }
            #expect(asked == ["keyDown cmd+t", "keyDown k", "keyUp k"], "asked about \(asked)")
            let commandT = try #require(delegate.asked.first)
            #expect(commandT.keyCode == Int(KeyCodes.code(for: "t")!) && commandT.charactersIgnoringModifiers == "t")
            #expect(!commandT.isInEditableField)

            // In a text field the same applies, and the delegate learns the focus is in an editable field.
            delegate.reset()
            _ = try await driver.eval("document.getElementById('field').focus(); return true")
            try await waitUntil("the field has focus and WebKit knows it", timeout: 5) {
                try await driver.bool("return document.activeElement.id === 'field'") && webView.inputContext != nil
            }
            try driver.key(KeyCodes.code(for: "t")!, characters: "t", modifiers: .command)
            try driver.key(KeyCodes.code(for: "a")!, characters: "a")
            let typed = try await waitFor("the field got a", timeout: 5) { () -> String? in
                let value = try await driver.string("return document.getElementById('field').value")
                let keys = try await pageKeys(driver)
                return value == "a" && keys.contains("keyup a") ? value : nil
            }
            #expect(typed == "a", "Command T reached the field")
            #expect(try await pageKeys(driver).suffix(2) == ["keydown a", "keyup a"])
            #expect(delegate.asked.map(\.isInEditableField) == [true, true, true])
        }
        try await rig.finish()
    }
}
