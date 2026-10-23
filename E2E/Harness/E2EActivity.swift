import Foundation

/// The tab activity log as a test sees it.
@MainActor
protocol E2EActivityApp: E2EApp {
    /// When the sidebar item behind `page`'s tab was last recorded active, nil if never.
    func activityTime(of page: any E2EPage) throws -> Date?
}
