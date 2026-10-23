import Foundation

// How the app decides where a page's new page opens. The engine asks synchronously, as the page opens it.

/// Where a new page the page opened goes.
public enum PopupDecision: Equatable, Sendable {
    /// A new tab, shown at once. The engine hands it to `EngineTabDelegate.tab(_:didOpenPopup:request:)`.
    case foregroundTab
    /// A new tab left in the background, handed over the same way.
    case backgroundTab
    /// A small window attached to the opener's window (a sign in popup), not a sidebar tab. The engine creates the
    /// page as it does for `.foregroundTab` and hands it over the same way, so it keeps `window.opener`; the app
    /// shows it in the panel (`PopupPanelLayout` sizes it).
    case popupPanel
    /// A Peek: a card over the opener's window, owned by the opener's sidebar item, not a sidebar tab. The engine
    /// creates the page as it does for `.foregroundTab` and hands it over the same way; the app shows it in the card
    /// and may later promote it to a tab without reloading it.
    case peek
    /// A separate window the engine opens itself. Today's behavior and the default.
    case window
    /// Nothing opens.
    case block
}

/// The window features a page passed to `window.open`: each value is nil when the page did not set it.
public struct PopupWindowFeatures: Equatable, Sendable {
    public var x: Int?
    public var y: Int?
    public var width: Int?
    public var height: Int?
    /// True when the features ask for a popup window rather than a tab (a size, or `popup`).
    public var isPopup: Bool

    public init(x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil, isPopup: Bool = false) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isPopup = isPopup
    }
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision {
        .window
    }

    public func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest) {
        // Nobody takes the tab: close it, so a page never lives on unseen.
        Task { _ = await newTab.close() }
    }
}
