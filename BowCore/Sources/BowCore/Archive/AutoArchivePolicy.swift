import Foundation

/// Decides which Today items auto-archive should move out now. Pure: the sidebar, the last active times, the
/// thresholds and the clock all come in as arguments.
public struct AutoArchivePolicy: Sendable {
    private let time: any TimeSource

    public init(time: any TimeSource = SystemTimeSource()) { self.time = time }

    /// The items to archive, in sidebar order.
    ///
    /// Only items in a Space's Today section (its unpinned container) are looked at, so pinned items and Favorites are
    /// never archived. A tab expires when it has been idle for at least its Space's threshold. A split moves as a
    /// whole once every one of its tabs has expired; its tabs are never archived one by one. Folders stay and their
    /// tabs are judged one by one.
    ///
    /// - Parameters:
    ///   - lastActive: when each tab was last active. A tab with no record is never archived, because its idle time
    ///     is unknown.
    ///   - threshold: the auto-archive threshold of a Space (it belongs to the Space's profile).
    ///   - keeping: tabs that must stay, such as ones playing audio or using the camera. The selected tab always stays.
    public func expiredItems(
        in graph: SidebarGraph,
        lastActive: [SidebarItemID: Date],
        threshold: (SidebarSpace) -> AutoArchiveThreshold,
        keeping: Set<SidebarItemID> = []
    ) -> [SidebarItemID] {
        let now = time.now
        var kept = keeping
        if let active = graph.activeTabID { kept.insert(active) }

        func isExpired(_ tab: SidebarItemID, after interval: TimeInterval) -> Bool {
            guard !kept.contains(tab), let last = lastActive[tab] else { return false }
            return now.timeIntervalSince(last) >= interval
        }

        var result: [SidebarItemID] = []
        for space in graph.spaces {
            guard let interval = threshold(space).interval else { continue }
            func visit(_ id: SidebarItemID) {
                guard let item = graph[id] else { return }
                switch item.data {
                case .tab:
                    if isExpired(id, after: interval) { result.append(id) }
                case .split:
                    let tabs = item.childrenIDs
                    if !tabs.isEmpty, tabs.allSatisfy({ isExpired($0, after: interval) }) { result.append(id) }
                case .folder, .container:
                    item.childrenIDs.forEach(visit)
                }
            }
            visit(space.unpinnedContainerID)
        }
        return result
    }
}
