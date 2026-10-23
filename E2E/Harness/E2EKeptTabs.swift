import Foundation

/// Pages of closed tabs kept alive for their downloads, as a test sees them: whether the engine keeps any, what their
/// pages asked for and were refused, and what could have shown on screen. E2E/Harness/E2EAppAdapter+KeptTabs.swift
/// implements it; it only reads state.
@MainActor
protocol E2EKeptTabsApp: E2EApp {
    /// True while the engine keeps a closed tab's page alive until its downloads end.
    var keepsClosedTabsForDownloads: Bool { get }
    /// How many browsers the engine has open or is creating, popups included.
    var openBrowserCount: Int { get }
    /// How many UI requests of `kind` (`popup`, `dialog`, `download`, `permission`, `file dialog`, `context menu`)
    /// pages of closed tabs made and were refused so far in this run.
    func refusedParkedRequests(of kind: String) -> Int
    /// How many of the app's windows are visible (off-screen test windows included), and whether a modal window or
    /// panel is up: what a page's popup window or dialog would add.
    var shownWindows: (visible: Int, modal: Bool) { get }
}
