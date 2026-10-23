import Foundation

/// The window's Peek as a test sees it. E2E/Harness/E2EAppAdapter+Peek.swift implements it over the window's
/// PeekFeature; every action is refused once the test has ended.
@MainActor
protocol E2EPeekApp: E2EPopupsApp {
    /// The Peek `page`'s window shows, nil while it shows none.
    func peek(besides page: any E2EPage) throws -> E2EPeekState?
    /// Waits until `page`'s window shows a Peek and returns its page, tracked for the test from then on (its events,
    /// leave prompts and DevTools session, as a tab's page). Throws when none shows within the wait's budget.
    func untilPeek(besides page: any E2EPage) async throws -> any E2EPage
    /// Waits until `page`'s window shows no Peek and returns whether it did within the wait's budget.
    func untilNoPeek(besides page: any E2EPage) async throws -> Bool
    /// Presses one of the Peek card's buttons the way a click does (the button's own action).
    func press(_ button: E2EPeekButton, besides page: any E2EPage) throws
    /// Presses the dimmed page around the card, as a click there does.
    func pressPeekBackdrop(besides page: any E2EPage) throws
    /// Sets Arc's two Peek settings for the app. A test that changes them calls `resetPeekSettings()` when it ends.
    func setPeekSettings(shiftClick: Bool, offSiteLinks: Bool) throws
    /// Puts both Peek settings back to Arc's defaults, also once the test has ended.
    func resetPeekSettings()
    /// How many browsers the engine has open or is creating, popups and Peeks included.
    var openBrowsers: Int { get }
}

/// A Peek's card buttons.
enum E2EPeekButton: String {
    case openAsTab = "Open as Tab"
    case close = "Close"
}

/// A Peek as a test sees it.
struct E2EPeekState: Equatable {
    /// The Peek page's title.
    var title: String
    /// True when the card sits above every pane of the page area, under a dimmed backdrop.
    var overPanes: Bool
    var dimmed: Bool
    /// True when the card's host view shows the Peek's page.
    var showsPage: Bool
}
