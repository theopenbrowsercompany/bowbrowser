import Foundation

/// What the back, forward, reload and stop controls of a window offer for its active tab, read from the state the
/// engine pushed last. The toolbar buttons and the menu items both follow it, so they always agree.
public struct NavigationControls: Equatable, Sendable {
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// True while a tab is open: reloading is always possible, even while the page loads.
    public var canReload: Bool
    /// True while the active tab is loading: the reload button shows stop, and stop is possible.
    public var isLoading: Bool

    /// Every control off, for a window with no open tab.
    public static let disabled = NavigationControls(
        canGoBack: false, canGoForward: false, canReload: false, isLoading: false)

    public init(canGoBack: Bool, canGoForward: Bool, canReload: Bool, isLoading: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.canReload = canReload
        self.isLoading = isLoading
    }

    /// The controls for a tab whose last pushed snapshot is `state`; a closed tab offers nothing.
    public init(state: EngineTabState, isClosed: Bool) {
        guard !isClosed else {
            self = .disabled
            return
        }
        self.init(
            canGoBack: state.canGoBack, canGoForward: state.canGoForward, canReload: true, isLoading: state.isLoading)
    }

    /// True when stop would do something: only while the page loads.
    public var canStop: Bool { isLoading }
}
