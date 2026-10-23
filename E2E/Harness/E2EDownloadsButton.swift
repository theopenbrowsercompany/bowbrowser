import Foundation

/// The sidebar footer's downloads button as a test sees it.
@MainActor
protocol E2EDownloadsButtonApp: E2EApp {
    /// Clicks the downloads button in the footer of the window `page` is in; throws when it is not there.
    func clickDownloadsButton(in page: any E2EPage) throws
    /// True while the button shows a running download (its symbol is the filled one).
    func downloadsButtonShowsActivity(in page: any E2EPage) throws -> Bool
    /// Hides the downloads window (opening it off screen first when needed), so a click can be seen to show it.
    func hideDownloadsWindow() async throws
    /// How many downloads windows are showing.
    func visibleDownloadsWindowCount() -> Int
}
