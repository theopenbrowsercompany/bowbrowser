import Foundation

/// What an import of history and bookmarks would bring, built from what was read and where each profile goes,
/// with no side effects.
public struct ChromiumImportPreview: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let data: ChromiumProfileData
        public let target: ChromiumProfileTarget
        /// The visits that go into history (see `ChromiumImportMapping.historyVisits`).
        public let visits: [HistoryImportVisit]
    }

    public let entries: [Entry]

    /// Maps each profile read to its Bow profile (see `ChromiumImportMapping.targets`).
    public init(data: [ChromiumProfileData], isKnown: (SidebarProfileID) -> Bool, fallback: SidebarProfileID) {
        let targets = ChromiumImportMapping.targets(for: data.map(\.profile), isKnown: isKnown, fallback: fallback)
        entries = zip(data, targets).map { data, target in
            Entry(data: data, target: target, visits: ChromiumImportMapping.historyVisits(from: data.visits))
        }
    }

    public var visitCount: Int { entries.reduce(0) { $0 + $1.visits.count } }
    public var bookmarkCount: Int { entries.reduce(0) { $0 + ($1.data.bookmarks?.bookmarkCount ?? 0) } }

    /// Whether the import would bring nothing with the bookmarks choice `choice`.
    public func isEmpty(bookmarks choice: ChromiumBookmarksChoice) -> Bool {
        visitCount == 0 && (choice == .skip || bookmarkCount == 0)
    }

    /// One line per profile for the wizard: its name, what it brings, and which Bow profile it goes to, saying so
    /// when no Bow profile matched. Then one line per problem.
    public func lines(
        bookmarks choice: ChromiumBookmarksChoice, profileName: (SidebarProfileID) -> String, fallbackSpaceTitle: String
    ) -> [String] {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var lines: [String] = []
        for entry in entries {
            var parts = [plural(entry.visits.count, "visit")]
            if let bookmarks = entry.data.bookmarks, choice == .pinnedFolder {
                parts.append(plural(bookmarks.bookmarkCount, "bookmark"))
            }
            let line = "\(entry.data.profile.displayName): " + parts.joined(separator: " and ")
            if entry.target.matched {
                lines.append(line + ", into the \(profileName(entry.target.bowProfile)) profile.")
            } else {
                lines.append(
                    line + ". No Bow profile matches this Arc profile, so it goes to the profile of the Space on "
                        + "screen, \(fallbackSpaceTitle).")
            }
        }
        for entry in entries {
            for problem in entry.data.problems { lines.append("\(entry.data.profile.displayName): \(problem).") }
        }
        return lines
    }

    /// The bookmarks folders to add for `choice`: one per profile with bookmarks, in the Space
    /// `ChromiumImportMapping.bookmarksSpace` picks in `graph`. Empty when bookmarks are skipped.
    public func bookmarkFolders(_ choice: ChromiumBookmarksChoice, in graph: SidebarGraph) -> [ChromiumBookmarkFolder] {
        guard choice == .pinnedFolder else { return [] }
        let withBookmarks = entries.filter { ($0.data.bookmarks?.bookmarkCount ?? 0) > 0 }
        return withBookmarks.compactMap { entry in
            guard let bookmarks = entry.data.bookmarks,
                let space = ChromiumImportMapping.bookmarksSpace(for: entry.target.bowProfile, in: graph)
            else { return nil }
            let title = ChromiumImportMapping.bookmarksFolderTitle(
                for: entry.data.profile, profilesWithBookmarks: withBookmarks.count)
            return ChromiumBookmarkFolder(spaceID: space, title: title, bookmarks: bookmarks)
        }
    }
}
