import AppKit
import BowCore
import WebKit

// Keys the app may claim before the page sees them (`EngineTabDelegate.tab(_:handleKeyBeforePage:)`). The tab's web
// view asks from `performKeyEquivalent`, `keyDown` and `keyUp` (WebKitWebView.swift); claiming a key down also claims
// the key up of the same press, which is then not asked about, as the CEF engine does.

extension WebKitTab: KeyBeforePageHandler {
    func handleKeyBeforePage(_ event: NSEvent, kind: KeyBeforePageKind, in webView: WebKitWebView) -> Bool {
        guard webView === self.webView, let delegate else { return false }
        return delegate.tab(self, handleKeyBeforePage: EngineKeyEvent(event, kind: kind, in: webView))
    }
}

extension EngineKeyEvent {
    /// The engine neutral form of AppKit key event `event` on its way to `webView`'s page. A field has focus when
    /// WebKit gives the view a text input context, which it does only while the focused element is editable.
    @MainActor
    init(_ event: NSEvent, kind: KeyBeforePageKind, in webView: WKWebView) {
        var modifiers: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(
            kind: kind == .keyDown ? .keyDown : .keyUp,
            keyCode: Int(event.keyCode),
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            modifiers: modifiers,
            isInEditableField: webView.inputContext != nil
        )
    }
}
