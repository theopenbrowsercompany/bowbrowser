import Foundation

/// Moves items between the sidebar and the archive, keeping the two files consistent.
///
/// Archiving writes the archive first and then removes the items from the sidebar; putting back does the opposite.
/// A crash between the two steps therefore never loses an item: it may exist in both places, and the next attempt
/// resolves it (archiving again replaces the entry, putting back drops an entry whose item is already in the sidebar).
public struct ArchiveService {
    public let sidebar: SidebarStore
    public let archived: ArchiveStore
    private let time: any TimeSource

    public init(sidebar: SidebarStore, archive: ArchiveStore, time: any TimeSource = SystemTimeSource()) {
        self.sidebar = sidebar
        self.archived = archive
        self.time = time
    }

    /// Archives items from Today. Refuses the whole request, changing nothing, if any item is not eligible: pinned
    /// items, Favorites and sections cannot be archived. Returns the new entries in the order given.
    @discardableResult
    public func archive(_ ids: [SidebarItemID], reason: ArchivedEntry.Reason) throws -> [ArchivedEntry] {
        let graph = sidebar.graph
        let date = time.now
        var seen: Set<SidebarItemID> = []
        var entries: [ArchivedEntry] = []
        for id in ids where seen.insert(id).inserted {
            entries.append(try ArchivedEntry.capture(id, from: graph, reason: reason, at: date))
        }
        // An item under another archived item travels with it.
        let all = Set(entries.map(\.id))
        entries.removeAll { entry in
            var parent = graph[entry.id]?.parentID
            while let next = parent {
                if all.contains(next) { return true }
                parent = graph[next]?.parentID
            }
            return false
        }
        guard !entries.isEmpty else { return [] }
        try archived.add(entries)
        try sidebar.apply(entries.map { .delete($0.id) })
        return entries
    }

    /// Archives everything the policy says has expired, using each Space's threshold.
    @discardableResult
    public func runAutoArchive(
        policy: AutoArchivePolicy,
        lastActive: [SidebarItemID: Date],
        threshold: (SidebarSpace) -> AutoArchiveThreshold,
        keeping: Set<SidebarItemID> = []
    ) throws -> [ArchivedEntry] {
        let expired = policy.expiredItems(
            in: sidebar.graph, lastActive: lastActive, threshold: threshold, keeping: keeping)
        return try archive(expired, reason: .auto)
    }

    /// Puts an archived item back where it was, then forgets the entry. Returns the restored item's ID.
    @discardableResult
    public func putBack(_ id: SidebarItemID) throws -> SidebarItemID {
        guard let entry = archived.entry(for: id) else { throw ArchiveError.entryNotFound(id) }
        do {
            try sidebar.apply(try entry.putBackMutations(into: sidebar.graph))
        } catch ArchiveError.alreadyInSidebar(let existing) where existing == id {
            // An earlier put back restored the item but stopped before forgetting the entry.
        }
        try archived.remove([id])
        return id
    }
}
