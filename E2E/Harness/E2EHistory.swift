import Foundation

/// One page in a profile's history as a test reads it.
struct E2EHistoryEntry: Equatable {
    var url: URL
    var title: String
    var visitCount: Int
}

/// The app's browsing history as a test sees it.
@MainActor
protocol E2EHistoryApp: E2EApp {
    /// The history the app holds for the profile `page`'s tab was created in, oldest visit first. Empty when the
    /// profile recorded nothing.
    func historyEntries(of page: any E2EPage) throws -> [E2EHistoryEntry]
    /// The history file of the profile `page`'s tab was created in, nil when its history is in memory only (or none
    /// was made).
    func historyFile(of page: any E2EPage) throws -> URL?
    /// The history read back from `file` by a store of its own, as a relaunch would read it, oldest visit first.
    func historyEntries(inFile file: URL) throws -> [E2EHistoryEntry]
    /// The folder that holds every persistent profile's history folder.
    func historyDirectory(of page: any E2EPage) throws -> URL
}
