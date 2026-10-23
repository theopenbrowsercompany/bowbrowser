import Foundation

/// The tab unloader as a test sees it: its setting, a clock the test moves, simulated memory pressure, and each
/// tab's row and page. E2E/Harness/E2EAppAdapter+Unload.swift implements it; every action but `resetUnloader` is
/// refused once the test has ended.
@MainActor
protocol E2EUnloadApp: E2EApp {
    /// Turns the "unload tabs" setting on or off.
    func setUnloadEnabled(_ enabled: Bool) throws
    /// Whether the unloader's timer and memory pressure source are running.
    var unloaderIsRunning: Bool { get }
    /// Gives the unloader a clock that starts now and moves only with `advanceUnloadClock(by:)`.
    func useManualUnloadClock() throws
    func advanceUnloadClock(by interval: TimeInterval) throws
    /// Runs one unload pass, as its timer does, and returns how many tabs it unloaded once each has answered.
    func runUnloadPass() async throws -> Int
    /// Reports memory pressure (`warning` or `critical`) as the system does, and returns how many tabs its pass
    /// unloaded.
    func simulateMemoryPressure(_ level: String) async throws -> Int
    /// Unloads `page`'s tab through the engine directly, without the unloader. Returns whether it unloaded.
    func unloadThroughEngine(_ page: any E2EPage) async throws -> Bool
    /// The sidebar item of `page`'s tab, read while it is loaded.
    func unloadItem(of page: any E2EPage) throws -> String
    /// Sidebar tab `item` of `page`'s window as the checks read it.
    func unloadTabState(_ item: String, besides page: any E2EPage) throws -> E2EUnloadTabState
    /// Reports that `page` started or stopped playing sound, as a frame's sound signal from the page would.
    func setTabAudible(_ audible: Bool, _ page: any E2EPage) throws
    /// Puts `text` on the general pasteboard and chooses Edit > Paste (its Command-V item, through the menu, so no
    /// key event reaches the page) in `page`'s window, then waits for `pasted` before putting the pasteboard's earlier
    /// contents back. The engine reads the pasteboard after the menu item returns, so `pasted` must wait for the page
    /// to have the text. Returns `pasted`'s last answer.
    func pasteThroughEditMenu(
        _ text: String, in page: any E2EPage, until pasted: @MainActor () async throws -> Bool
    ) async throws -> Bool
    /// The unload placeholder of `page`'s window: the one up now, and when each came and went.
    func unloadPlaceholder(besides page: any E2EPage) throws -> E2EUnloadPlaceholder
    /// Writes a PNG of `page`'s window as AppKit draws it (web content blank, the placeholder drawn) to `url`.
    func writeWindowScreenshot(besides page: any E2EPage, to url: URL) throws
    /// Turns the setting off and puts the real clock back. Never refused, so a test can always clean up.
    func resetUnloader()
}

/// A window's unload placeholder as the checks read it.
struct E2EUnloadPlaceholder: Equatable {
    /// The sidebar item of the tab it stands in for, nil when none is up.
    var item: String?
    var title: String
    /// It is in the window's view hierarchy.
    var inWindow: Bool
    /// "shown <item>" and "hidden <item> <why>" (finish, fail, switch, close...), oldest first.
    var log: [String]
}

/// One sidebar tab as the unload checks read it.
struct E2EUnloadTabState: Equatable {
    /// The window lists its row.
    var isListed: Bool
    /// It has an open page.
    var isLoaded: Bool
    /// The window shows its page.
    var isShown: Bool
    /// The address its row has (its page's while loaded).
    var url: String
    var title: String
    /// Its page is using the camera or microphone.
    var isCapturing: Bool
    /// The window holds no page for it (it has heard the page closed or unloaded).
    var isReleased: Bool
    /// Its row shows a site icon.
    var hasFavicon: Bool
    /// Its page reports playing sound.
    var isAudible: Bool
    /// Its page reports a form field the person edited.
    var hasEditedForm: Bool
}
