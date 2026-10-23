import AppKit
import BowCore

// The kept tabs area of the adapter: E2EKeptTabsApp over the engine and the engine's e2e counters. Reading only, so
// nothing here checks that the test is still running.

extension E2ETestApp: E2EKeptTabsApp {
    var keepsClosedTabsForDownloads: Bool { adapter.delegate.engine.keepsClosedTabsForDownloads }

    var openBrowserCount: Int { adapter.openBrowserCount }

    func refusedParkedRequests(of kind: String) -> Int {
        BowOpenBrowsers.refusedParkedRequests(of: kind)
    }

    var shownWindows: (visible: Int, modal: Bool) {
        (NSApp.windows.filter(\.isVisible).count, NSApp.modalWindow != nil || NSApp.windows.contains { $0.isSheet })
    }
}
