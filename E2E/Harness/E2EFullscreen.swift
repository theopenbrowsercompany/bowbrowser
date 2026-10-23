import Foundation

// Page fullscreen as a test sees it: the window's chrome and page card, and a recorder that stands in for macOS full
// screen, so a run never takes over the display. E2E/Harness/E2EAppAdapter+Fullscreen.swift implements it; every
// action is refused once the test has ended.

/// A page's window as page fullscreen leaves it now.
struct E2EFullscreenState: Equatable, CustomStringConvertible {
    /// True while the window's page fullscreen feature has a page filling the window.
    var pageFills: Bool
    var sidebarHidden: Bool
    /// True while the top tabs bar (the strip and the toolbar row) shows.
    var topBarShown: Bool
    /// The card's insets (top, leading, bottom, trailing) as the window's page container has them.
    var pageInsets: [Double]
    var pageRadius: Double
    var hasShadow: Bool
    /// How many times the window's full screen was toggled since the recorder was installed, and its state now.
    var toggles: Int
    var windowFullScreen: Bool
    /// The recorder's transition in progress: "entering", "exiting", or "none".
    var windowTransition: String

    var restoredSidebarLayout: Bool {
        !pageFills && !sidebarHidden && !topBarShown && pageInsets == [8, 0, 8, 8] && pageRadius == 10 && hasShadow
    }

    var fillsWindow: Bool {
        pageFills && sidebarHidden && !topBarShown && pageInsets == [0, 0, 0, 0] && pageRadius == 0 && !hasShadow
    }

    var description: String {
        "sidebar=\(sidebarHidden ? "hidden" : "shown") top-bar=\(topBarShown ? "shown" : "hidden") "
            + "insets=\(pageInsets.map { Int($0) }) radius=\(Int(pageRadius)) shadow=\(hasShadow) "
            + "page-fills=\(pageFills) toggles=\(toggles) window-full-screen=\(windowFullScreen) "
            + "transition=\(windowTransition)"
    }
}

@MainActor
protocol E2EFullscreenApp: E2EApp {
    /// Puts a recorder in place of `page`'s window's macOS full screen, starting in full screen or not; the window
    /// feature then believes the recorder, and a toggle only flips it and counts.
    func recordWindowFullScreen(of page: any E2EPage, startingFullScreen: Bool) throws
    /// `page`'s window now.
    func fullscreenState(of page: any E2EPage) throws -> E2EFullscreenState
    /// The window leaves macOS full screen the way the system reports it (the green button): the recorder goes out
    /// of full screen and the window posts its did exit full screen notification.
    func leaveWindowFullScreen(of page: any E2EPage) throws
    /// From now on each toggle of `page`'s recorded full screen starts a transition and holds it, as macOS animates:
    /// the recorder posts the window's will enter or will exit full screen notification at once, ignores (but counts)
    /// toggles until the transition ends, and ends it only when the test calls `finishWindowFullScreenTransition`.
    func holdWindowFullScreenTransitions(of page: any E2EPage) throws
    /// Ends the held transition: the recorder takes the new state and the window posts its did enter or did exit
    /// full screen notification, which the window's feature handles as it does for a real window. Throws when no
    /// transition is in progress.
    func finishWindowFullScreenTransition(of page: any E2EPage) throws
}
