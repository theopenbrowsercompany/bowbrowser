import Foundation

/// What an import of one Chromium profile would bring in, computed without writing anything (a dry run).
/// Cookies, passwords and extensions are never read, so they have no counts here.
public struct ChromiumImportSummary: Equatable, Sendable {
    public let profile: ChromiumProfile
    public let visitCount: Int
    public let distinctURLCount: Int
    public let earliestVisit: Date?
    public let latestVisit: Date?
    public let bookmarkCount: Int
    public let bookmarkFolderCount: Int
    /// Files that were missing or unreadable, so the person sees a partial result instead of nothing.
    public let problems: [ChromiumImportError]

    /// A one line description for the import sheet or a log.
    public var text: String {
        var parts = ["\(profile.displayName): \(visitCount) visits to \(distinctURLCount) pages"]
        parts.append("\(bookmarkCount) bookmarks in \(bookmarkFolderCount) folders")
        if !problems.isEmpty { parts.append("problems: " + problems.map(\.description).joined(separator: "; ")) }
        return parts.joined(separator: ", ")
    }

    public init(
        profile: ChromiumProfile, visits: [ChromiumVisit], bookmarks: ChromiumBookmarks?,
        problems: [ChromiumImportError] = []
    ) {
        self.profile = profile
        visitCount = visits.count
        distinctURLCount = Set(visits.map(\.url)).count
        earliestVisit = visits.map(\.date).min()
        latestVisit = visits.map(\.date).max()
        bookmarkCount = bookmarks?.bookmarkCount ?? 0
        bookmarkFolderCount = bookmarks?.folderCount ?? 0
        self.problems = problems
    }

    /// Reads one profile folder and summarizes it. A missing or broken Bookmarks or History file is recorded in
    /// `problems` and the other file is still summarized.
    public static func dryRun(userDataFolder: URL, profile: ChromiumProfile) -> ChromiumImportSummary {
        let folder = userDataFolder.appendingPathComponent(profile.directory, isDirectory: true)
        var problems: [ChromiumImportError] = []
        var visits: [ChromiumVisit] = []
        var bookmarks: ChromiumBookmarks?
        do { visits = try ChromiumHistory.load(profileFolder: folder) } catch let e as ChromiumImportError {
            problems.append(e)
        } catch {}
        do { bookmarks = try ChromiumBookmarks.load(profileFolder: folder) } catch let e as ChromiumImportError {
            problems.append(e)
        } catch {}
        return ChromiumImportSummary(profile: profile, visits: visits, bookmarks: bookmarks, problems: problems)
    }
}
