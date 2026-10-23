import Foundation

/// Where one Chromium profile's history and bookmarks go in Bow.
public struct ChromiumProfileTarget: Equatable, Sendable {
    public let profile: ChromiumProfile
    /// The Bow profile its visits go into.
    public let bowProfile: SidebarProfileID
    /// True when `bowProfile` is the profile Bow keeps for this Arc profile: Bow's default profile for Arc's
    /// `Default`, or the profile a sidebar import made for any other. False when Bow has no such profile, so the
    /// visits go to the profile of the Space on screen instead, which the preview says.
    public let matched: Bool

    public init(profile: ChromiumProfile, bowProfile: SidebarProfileID, matched: Bool) {
        self.profile = profile
        self.bowProfile = bowProfile
        self.matched = matched
    }
}

/// Whether bookmarks come along, as the person chooses in the wizard.
public enum ChromiumBookmarksChoice: String, CaseIterable, Equatable, Sendable {
    /// Each profile's bookmarks become one folder in a Space's pinned section, keeping their nesting. The default.
    case pinnedFolder
    case skip
}

/// The decisions of importing history and bookmarks from a Chromium User Data folder: which Bow profile each
/// Chromium profile maps to, which visits come across and how, and where a profile's bookmarks folder goes.
public enum ChromiumImportMapping {
    /// The name of the folder that holds one profile's bookmarks.
    public static let bookmarksFolderTitle = "Arc Bookmarks"

    /// The Bow profile Arc keeps for the Chromium profile folder `directory`: Bow's default profile for `Default`,
    /// and otherwise the ID a sidebar import gives that Arc profile (`ArcImportProfileTarget.profileID`), so the
    /// history lands where the Spaces of the same Arc profile already are.
    public static func bowProfileID(forDirectory directory: String) -> SidebarProfileID {
        directory == "Default" ? .default : ArcImportProfileTarget.profileID(forArcProfile: directory)
    }

    /// Maps each Chromium profile, in order, to the Bow profile its visits go into. `isKnown` says whether Bow has a
    /// profile (the default one always counts); a profile with no match goes to `fallback`, the profile of the Space
    /// on screen.
    public static func targets(
        for profiles: [ChromiumProfile], isKnown: (SidebarProfileID) -> Bool, fallback: SidebarProfileID
    ) -> [ChromiumProfileTarget] {
        profiles.map { profile in
            let id = bowProfileID(forDirectory: profile.directory)
            let known = id == .default || isKnown(id)
            return ChromiumProfileTarget(profile: profile, bowProfile: known ? id : fallback, matched: known)
        }
    }

    /// Bow's transition for a Chromium core transition (the low byte of `visits.transition`), nil for a visit Bow
    /// would not have recorded: reloads, and subframe loads (which the reader already leaves out).
    public static func transition(fromChromium core: Int) -> NavigationTransition? {
        switch core {
        case 0: .link
        case 1: .typed
        case 3, 4, 8: nil
        case 7: .formSubmit
        default: .other
        }
    }

    /// The visits to bring into Bow's history: one per Chromium visit Bow would have recorded, with its time,
    /// title and transition. Visits whose URL does not parse are left out.
    public static func historyVisits(from visits: [ChromiumVisit]) -> [HistoryImportVisit] {
        visits.compactMap { visit in
            guard let transition = transition(fromChromium: visit.transition), let url = URL(string: visit.url) else {
                return nil
            }
            return HistoryImportVisit(url: url, title: visit.title, time: visit.date, transition: transition)
        }
    }

    /// The Space whose pinned section takes the bookmarks of Bow profile `profile`: the Space on screen when it
    /// uses that profile, else the first Space that does, else the Space on screen. Nil when there is no Space.
    public static func bookmarksSpace(for profile: SidebarProfileID, in graph: SidebarGraph) -> SidebarSpaceID? {
        if let active = graph.activeSpace, active.profileID == profile { return active.id }
        if let first = graph.spaces.first(where: { $0.profileID == profile }) { return first.id }
        return graph.activeSpace?.id ?? graph.spaces.first?.id
    }

    /// The bookmarks folder's name: `Arc Bookmarks`, followed by the profile's name in parentheses when more than
    /// one profile brings bookmarks, so their folders stay apart.
    public static func bookmarksFolderTitle(for profile: ChromiumProfile, profilesWithBookmarks: Int) -> String {
        profilesWithBookmarks > 1 ? "\(bookmarksFolderTitle) (\(profile.displayName))" : bookmarksFolderTitle
    }
}

/// One profile's bookmarks, bound for one folder in a Space's pinned section.
public struct ChromiumBookmarkFolder: Equatable, Sendable {
    public var spaceID: SidebarSpaceID
    public var title: String
    public var bookmarks: ChromiumBookmarks

    public init(spaceID: SidebarSpaceID, title: String, bookmarks: ChromiumBookmarks) {
        self.spaceID = spaceID
        self.title = title
        self.bookmarks = bookmarks
    }
}

/// What one bookmarks import added to the sidebar, enough to take exactly that out again.
public struct ChromiumBookmarksApplied: Equatable, Sendable {
    /// Every folder and tab the import inserted, parents before their children.
    public var insertedIDs: [SidebarItemID] = []
    /// The folder or pinned section each inserted item was added to.
    public var parentIDs: [SidebarItemID: SidebarItemID] = [:]
    /// How many bookmarks (tabs) were added, and how many were already there and left out.
    public var addedBookmarks = 0
    public var knownBookmarks = 0
    /// Set when the change is in the sidebar but writing the file failed. The store keeps retrying on its next save.
    public var saveFailure: String?

    public var isEmpty: Bool { insertedIDs.isEmpty }

    public init() {}

    /// Takes the bookmarks out again in one transaction. See `undoSteps(in:)`.
    public func undo(on store: SidebarStore) throws {
        guard !isEmpty else { return }
        try store.transaction { try undoSteps(in: store) }
    }

    /// Deletes, inside the store's open transaction, the items this import inserted that are still there, children
    /// first. A folder that still holds something else (a tab the person put in it) stays, with that inside it, so
    /// undo never deletes the person's own items; tabs the person moved out stay where they are.
    func undoSteps(in store: SidebarStore) throws {
        for id in insertedIDs.reversed() {
            // Gone, or moved by the person out of the folder it was added to: not the import's to delete any more.
            guard let item = store.transactionGraph?.items[id], item.parentID == parentIDs[id] else { continue }
            // Children were visited first, so anything still inside is the person's (or kept for them).
            if !item.childrenIDs.isEmpty { continue }
            try store.mutate(.delete(id))
        }
    }
}

public enum ChromiumBookmarkImport {
    /// Adds each folder of bookmarks to its Space's pinned section in one transaction, keeping the bookmark tree's
    /// nesting: the folder holds one folder per bookmark root that has anything (the bookmarks bar, other bookmarks,
    /// and so on), each holding its bookmarks and folders in order.
    ///
    /// Nothing is added twice: a folder of the same name already at the same place is used instead of a new one, and
    /// a bookmark whose address is already a tab directly in that folder is left out. Importing the same bookmarks
    /// again therefore adds nothing.
    @discardableResult
    public static func apply(_ folders: [ChromiumBookmarkFolder], to store: SidebarStore) throws
        -> ChromiumBookmarksApplied
    {
        var applied = ChromiumBookmarksApplied()
        guard !folders.isEmpty else { return applied }
        do {
            try store.transaction {
                for folder in folders {
                    guard let space = store.transactionGraph?.space(folder.spaceID) else {
                        throw SidebarStoreError.spaceNotFound(folder.spaceID)
                    }
                    let roots = folder.bookmarks.roots.filter { !$0.children.isEmpty }
                    guard !roots.isEmpty else { continue }
                    let top = try self.folder(folder.title, under: space.pinnedContainerID, in: store, &applied)
                    for root in roots {
                        let rootFolder = try self.folder(root.title, under: top, in: store, &applied)
                        try insert(root.children, under: rootFolder, in: store, &applied)
                    }
                }
            }
        } catch SidebarStoreError.saveFailed(let reason) {
            applied.saveFailure = reason
        }
        return applied
    }

    private static func insert(
        _ nodes: [ChromiumBookmarkNode], under parent: SidebarItemID, in store: SidebarStore,
        _ applied: inout ChromiumBookmarksApplied
    ) throws {
        for node in nodes {
            switch node {
            case .url(let title, let url, _):
                let known = store.transactionGraph?.children(of: parent).contains { item in
                    if case .tab(let tab) = item.data { return tab.savedURL == url }
                    return false
                }
                if known == true {
                    applied.knownBookmarks += 1
                    continue
                }
                let item = SidebarItem.tab(url: url, title: title)
                try store.mutate(.insert(item, parent: parent))
                applied.insertedIDs.append(item.id)
                applied.parentIDs[item.id] = parent
                applied.addedBookmarks += 1
            case .folder(let title, _, let children):
                let id = try folder(title, under: parent, in: store, &applied)
                try insert(children, under: id, in: store, &applied)
            }
        }
    }

    /// The folder called `title` directly under `parent`, inserted when there is none.
    private static func folder(
        _ title: String, under parent: SidebarItemID, in store: SidebarStore, _ applied: inout ChromiumBookmarksApplied
    ) throws -> SidebarItemID {
        let existing = store.transactionGraph?.children(of: parent).first { item in
            if case .folder = item.data { return item.title == title }
            return false
        }
        if let existing { return existing.id }
        let item = SidebarItem.folder(title: title)
        try store.mutate(.insert(item, parent: parent))
        applied.insertedIDs.append(item.id)
        applied.parentIDs[item.id] = parent
        return item.id
    }
}
