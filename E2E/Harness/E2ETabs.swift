import Foundation

/// Unloading a tab through the engine, as a test sees it. E2E/Harness/E2EAppAdapter+Tabs.swift implements it.
@MainActor
protocol E2ETabsApp: E2EApp {
    /// Asks the engine to unload the tab of `page`, as the unload policy will, and returns once the window has heard
    /// what came of it (at once when the engine refused).
    func unloadTab(_ page: any E2EPage) async throws -> E2EUnloadedTab
}

/// What became of a tab the engine was asked to unload, and the way back to it.
@MainActor
struct E2EUnloadedTab {
    /// Whether the engine unloaded the page.
    var unloaded: Bool
    /// The event the window heard for the tab: `unloaded`, `closed`, or `none` when the engine refused.
    var event: String
    /// Whether the window still holds the tab's page as one of its tabs.
    var windowHoldsPage: Bool
    /// The title the tab's sidebar row shows now, nil when the row is gone.
    var rowTitle: String?
    /// Chooses the tab's sidebar row as a click does, and returns the page the window then shows for that row, nil
    /// when the window shows no page for it.
    var choose: @MainActor () throws -> (any E2EPage)?
}
