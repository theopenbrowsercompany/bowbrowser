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
    private let hasBookmarks: Bool

    /// A one line description for the import sheet or a log.
    public var text: String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var parts = ["\(profile.displayName): \(plural(visitCount, "visit")) to \(plural(distinctURLCount, "page"))"]
        if hasBookmarks {
            parts.append("\(plural(bookmarkCount, "bookmark")) in \(plural(bookmarkFolderCount, "folder"))")
        }
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
        hasBookmarks = bookmarks != nil
    }

    /// Reads one profile folder and summarizes it. A missing or broken Bookmarks or History file is recorded in
    /// `problems` and the other file is still summarized.
    public static func dryRun(userDataFolder: URL, profile: ChromiumProfile) -> ChromiumImportSummary {
        guard ChromiumProfileList.isSafeDirectory(profile.directory) else {
            let bad = ChromiumImportError.malformed(file: profile.directory, reason: "not a profile folder name")
            return ChromiumImportSummary(profile: profile, visits: [], bookmarks: nil, problems: [bad])
        }
        let folder = userDataFolder.appendingPathComponent(profile.directory, isDirectory: true)
        var problems: [ChromiumImportError] = []
        var visits: [ChromiumVisit] = []
        var bookmarks: ChromiumBookmarks?
        do {
            let report = try ChromiumHistory.loadReport(profileFolder: folder)
            visits = report.visits
            if report.undatedCount > 0 { problems.append(.undatedVisits(count: report.undatedCount)) }
        } catch let e as ChromiumImportError {
            problems.append(e)
        } catch {
            problems.append(.database(file: ChromiumHistory.fileName, reason: "\(error)"))
        }
        do { bookmarks = try ChromiumBookmarks.load(profileFolder: folder) } catch let e as ChromiumImportError {
            problems.append(e)
        } catch {
            problems.append(.malformed(file: ChromiumBookmarks.fileName, reason: "\(error)"))
        }
        return ChromiumImportSummary(profile: profile, visits: visits, bookmarks: bookmarks, problems: problems)
    }
}
