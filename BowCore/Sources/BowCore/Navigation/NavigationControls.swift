import Foundation

/// What the back, forward, reload and stop controls of a window offer for its active tab, read from the tab model
/// (`BrowserTab`), into which the engine's pushed state is applied. The toolbar buttons and the menu items both
/// follow it, so they always agree.
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

    /// The controls for the active tab, or `disabled` when there is none (no tab, or it has closed).
    public init(activeTab tab: BrowserTab?) {
        guard let tab else {
            self = .disabled
            return
        }
        self.init(canGoBack: tab.canGoBack, canGoForward: tab.canGoForward, canReload: true, isLoading: tab.isLoading)
    }

    /// True when stop would do something: only while the page loads.
    public var canStop: Bool { isLoading }
}
