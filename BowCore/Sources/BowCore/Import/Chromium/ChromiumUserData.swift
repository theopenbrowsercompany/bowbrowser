import Foundation

/// What one Chromium profile holds for an import: its visits and bookmarks, and what could not be read.
public struct ChromiumProfileData: Equatable, Sendable {
    public let profile: ChromiumProfile
    public let visits: [ChromiumVisit]
    /// Nil when the profile has no readable Bookmarks file.
    public let bookmarks: ChromiumBookmarks?
    /// Files that were missing or unreadable, and visits left out, so the person sees a partial result.
    public let problems: [ChromiumImportError]

    public init(
        profile: ChromiumProfile, visits: [ChromiumVisit], bookmarks: ChromiumBookmarks?,
        problems: [ChromiumImportError]
    ) {
        self.profile = profile
        self.visits = visits
        self.bookmarks = bookmarks
        self.problems = problems
    }
}

/// Reads a Chromium User Data folder for an import of history and bookmarks.
///
/// Exactly three kinds of file are read: `Local State` at the top for the profile list, and in each listed profile's
/// folder `Bookmarks` (JSON, read whole) and `History` (copied with its `-wal` and `-journal` files, and only the copy
/// opened). Cookies, Login Data, Web Data, Extensions and every other file are never opened.
public enum ChromiumUserData {
    /// Why a folder cannot be imported from at all.
    public enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        /// No `Local State` file, or one that is not Chromium's: the folder is not a User Data folder.
        case notUserData(ChromiumImportError)
        /// `Local State` lists no profile.
        case noProfiles

        public var description: String {
            switch self {
            case .notUserData(let error): "This folder is not a Chromium User Data folder: \(error.description)."
            case .noProfiles: "This folder's Local State lists no profiles."
            }
        }
    }

    /// Reads every profile `Local State` lists, in its order. A profile whose files are missing or unreadable is
    /// still returned, with its problems and whatever could be read. `isCancelled` is asked before each profile, and
    /// a cancelled read returns what it has so far. Throws `Refusal` when the folder has no usable `Local State`.
    public static func read(
        _ folder: URL, temporaryFolder: URL? = nil, log: ChromiumFileLog? = nil,
        isCancelled: () -> Bool = { false }
    ) throws(Refusal) -> [ChromiumProfileData] {
        let profiles: [ChromiumProfile]
        do {
            profiles = try ChromiumProfileList.load(userDataFolder: folder, log: log)
        } catch let error as ChromiumImportError {
            throw .notUserData(error)
        } catch {
            throw .notUserData(.malformed(file: ChromiumProfileList.fileName, reason: "\(error)"))
        }
        guard !profiles.isEmpty else { throw .noProfiles }
        var result: [ChromiumProfileData] = []
        for profile in profiles {
            if isCancelled() { break }
            result.append(read(profile, in: folder, temporaryFolder: temporaryFolder, log: log))
        }
        return result
    }

    /// Reads one profile's History and Bookmarks. A missing or broken file is recorded and the other still read.
    static func read(_ profile: ChromiumProfile, in userData: URL, temporaryFolder: URL?, log: ChromiumFileLog?)
        -> ChromiumProfileData
    {
        let folder = userData.appendingPathComponent(profile.directory, isDirectory: true)
        var problems: [ChromiumImportError] = []
        var visits: [ChromiumVisit] = []
        var bookmarks: ChromiumBookmarks?
        do {
            let report = try ChromiumHistory.loadReport(
                profileFolder: folder, temporaryFolder: temporaryFolder, log: log)
            visits = report.visits
            if report.undatedCount > 0 { problems.append(.undatedVisits(count: report.undatedCount)) }
        } catch let error as ChromiumImportError {
            problems.append(error)
        } catch {
            problems.append(.database(file: ChromiumHistory.fileName, reason: "\(error)"))
        }
        do {
            bookmarks = try ChromiumBookmarks.load(profileFolder: folder, log: log)
        } catch let error as ChromiumImportError {
            problems.append(error)
        } catch {
            problems.append(.malformed(file: ChromiumBookmarks.fileName, reason: "\(error)"))
        }
        return ChromiumProfileData(profile: profile, visits: visits, bookmarks: bookmarks, problems: problems)
    }
}
