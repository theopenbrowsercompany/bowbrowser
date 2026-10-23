import Foundation

// Where a page's new page goes: the decision and, for a tab, where the tab lands. A pure function,
// so the window applies the result and the rules stay easy to change and test.

/// Where the page that opened a new page lives in the sidebar.
public enum PopupOpenerZone: Equatable, Sendable {
    case pinned
    case favorite
    case today
}

/// The modifier keys held during the click that opened the new page.
public struct PopupClickModifiers: Equatable, Sendable {
    public var command: Bool
    public var shift: Bool

    public init(command: Bool = false, shift: Bool = false) {
        self.command = command
        self.shift = shift
    }

    public static let none = PopupClickModifiers()
}

/// Where a new tab is inserted. The window applies it; the policy never touches the sidebar.
public enum PopupPlacement: Equatable, Sendable {
    /// Right after the tab that opened it, in Today.
    case afterOpener
    /// At the top of Today.
    case topOfToday
}

/// What to do with a request: the decision and, when it is a tab, where the tab goes.
public struct PopupOutcome: Equatable, Sendable {
    public var decision: PopupDecision
    /// Nil unless `decision` is a tab.
    public var placement: PopupPlacement?

    public init(decision: PopupDecision, placement: PopupPlacement? = nil) {
        self.decision = decision
        self.placement = placement
    }
}

/// The rules, as named values so each is easy to change.
public enum PopupPolicy {
    /// A plain `target="_blank"` link or Cmd-click.
    public static let plainLinkDecision = PopupDecision.backgroundTab
    /// Cmd-Shift-click.
    public static let commandShiftDecision = PopupDecision.foregroundTab
    /// Shift-click, the future Peek gesture: a foreground tab until Peek exists.
    public static let shiftDecision = PopupDecision.foregroundTab
    /// A request with no user gesture.
    public static let noGestureDecision = PopupDecision.block
    /// A sized `window.open` stays a window, so `window.opener` keeps working.
    public static let sizedPopupDecision = PopupDecision.window
    /// Where a tab opened from Today goes.
    public static let todayPlacement = PopupPlacement.afterOpener
    /// Where a tab opened from a pinned tab or a Favorite goes.
    public static let pinnedOrFavoritePlacement = PopupPlacement.topOfToday

    /// The modifiers come from the click, which the engine's disposition alone cannot tell apart
    /// (`target="_blank"` and Cmd-Shift-click both arrive as a foreground tab).
    public static func outcome(
        for request: PopupRequest,
        openerZone: PopupOpenerZone,
        modifiers: PopupClickModifiers = .none
    ) -> PopupOutcome {
        guard request.isUserGesture else { return PopupOutcome(decision: noGestureDecision) }
        if isSized(request) { return PopupOutcome(decision: sizedPopupDecision) }

        let decision: PopupDecision
        switch (modifiers.command, modifiers.shift) {
        case (true, true): decision = commandShiftDecision
        case (false, true): decision = shiftDecision
        default: decision = plainLinkDecision
        }
        let placement: PopupPlacement
        switch openerZone {
        case .today: placement = todayPlacement
        case .pinned, .favorite: placement = pinnedOrFavoritePlacement
        }
        return PopupOutcome(decision: decision, placement: placement)
    }

    private static func isSized(_ request: PopupRequest) -> Bool {
        request.requestedSize != nil
            || request.windowFeatures.width != nil
            || request.windowFeatures.height != nil
            || request.windowFeatures.isPopup
            || request.disposition == .popup
    }
}
