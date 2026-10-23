import Foundation

/// What `E2EReopenApp.reopenApp()` did.
struct E2EReopened {
    /// The delegate's answer: true when it left the reopen to the system (a window was on screen), false when it
    /// handled it itself.
    var leftToSystem: Bool
    /// The page of the new window's shown tab, nil when no window opened.
    var page: (any E2EPage)?
    /// The title of the Space the new window shows, nil when no window opened.
    var spaceTitle: String?
    /// The app's browser windows that are not closing, after the reopen.
    var windowCount: Int
}

/// The app being reopened (a click on the Dock icon), driven through the same delegate method AppKit calls, with the
/// window it opens made off screen.
@MainActor
protocol E2EReopenApp: E2EApp {
    /// Gives the app's own sidebar two Spaces, "Reopen A" and "Reopen B", each with a tab on `url`, and shows A. No
    /// window of the app may be open.
    func seedAppSidebar(url: URL) throws
    /// The app's browser windows that are not closing.
    func appWindowCount() throws -> Int
    /// Reopens the app as a click on its Dock icon does, and returns what happened.
    func reopenApp() async throws -> E2EReopened
    /// Shows the Space titled `title` in `page`'s window, through the window's own sidebar store.
    func showSpace(titled title: String, in page: any E2EPage) throws
}
