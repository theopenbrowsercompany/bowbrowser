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

    var restoredSidebarLayout: Bool {
        !pageFills && !sidebarHidden && !topBarShown && pageInsets == [8, 0, 8, 8] && pageRadius == 10 && hasShadow
    }

    var fillsWindow: Bool {
        pageFills && sidebarHidden && !topBarShown && pageInsets == [0, 0, 0, 0] && pageRadius == 0 && !hasShadow
    }

    var description: String {
        "sidebar=\(sidebarHidden ? "hidden" : "shown") top-bar=\(topBarShown ? "shown" : "hidden") "
            + "insets=\(pageInsets.map { Int($0) }) radius=\(Int(pageRadius)) shadow=\(hasShadow) "
            + "page-fills=\(pageFills) toggles=\(toggles) window-full-screen=\(windowFullScreen)"
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
}
