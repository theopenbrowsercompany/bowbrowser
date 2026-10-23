import Foundation

/// The most recently used items, newest first. The app keeps one per window and feeds it the tabs
/// a person activates, so Ctrl+Tab can return to the last tab used instead of the next one in order.
public struct RecencyList<ID: Hashable & Codable>: Codable, Equatable {
    /// Items in recency order, most recent first. Each item appears at most once.
    public private(set) var ids: [ID]

    /// The longest the list may grow, or nil for no limit. The least recent items drop off first.
    public let maxCount: Int?

    /// Creates an empty list. `maxCount`, when given, must be at least 1.
    public init(maxCount: Int? = nil) {
        precondition(maxCount.map { $0 >= 1 } ?? true, "maxCount must be at least 1")
        self.ids = []
        self.maxCount = maxCount
    }

    /// Records that `id` was used: it moves to the front, or enters the front if it was not listed.
    /// Trims the least recent items when the list is over `maxCount`.
    public mutating func use(_ id: ID) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        trim()
    }

    /// Removes `id`, for example when its tab closes. Does nothing when it is not listed.
    public mutating func remove(_ id: ID) {
        ids.removeAll { $0 == id }
    }

    /// Whether `id` is currently listed.
    public func contains(_ id: ID) -> Bool {
        ids.contains(id)
    }

    /// Starts a Ctrl+Tab switch over the current recency order, or returns nil when the list is empty.
    public func beginSwitch() -> RecencySwitch<ID>? {
        RecencySwitch(order: ids)
    }

    /// Drops every item that is not in `open`, for example after a restart when some saved tabs no
    /// longer exist. Remaining items keep their order.
    public mutating func keepOnly(_ open: Set<ID>) {
        ids.removeAll { !open.contains($0) }
    }

    /// Ends a switch by making the item it lands on the most recent, as if it had been used.
    /// The highlighted item is used when it is still listed. Otherwise the switch moves forward
    /// through its snapshot to the first item still listed, so a tab that closed mid-switch is skipped.
    /// Returns the committed item, or nil when none of the snapshot is still listed, in which case the
    /// list is left unchanged.
    @discardableResult
    public mutating func commit(_ switcher: RecencySwitch<ID>) -> ID? {
        let count = switcher.order.count
        for offset in 0..<count {
            let choice = switcher.order[(switcher.index + offset) % count]
            if contains(choice) {
                use(choice)
                return choice
            }
        }
        return nil
    }

    private mutating func trim() {
        if let maxCount, ids.count > maxCount {
            ids.removeSubrange(maxCount...)
        }
    }

    /// Saved lists may have been edited by hand or written by an older version, so duplicates are
    /// dropped (keeping the most recent occurrence) and the cap is applied again on load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = try container.decode([ID].self, forKey: .ids)
        let maxCount = try container.decodeIfPresent(Int.self, forKey: .maxCount)
        if let maxCount, maxCount < 1 {
            throw DecodingError.dataCorruptedError(
                forKey: .maxCount, in: container, debugDescription: "maxCount must be at least 1")
        }
        var list = RecencyList(maxCount: maxCount)
        for id in saved.reversed() {
            list.use(id)
        }
        self = list
    }

    private enum CodingKeys: String, CodingKey {
        case ids, maxCount
    }
}

/// One Ctrl+Tab session: a snapshot of the recency order and the item the switcher is on.
/// Stepping moves through the snapshot and wraps around. Nothing changes in the list until
/// `RecencyList.commit(_:)` is called with the finished session.
public struct RecencySwitch<ID: Hashable>: Equatable {
    /// The recency order when the switch began, most recent first.
    public let order: [ID]

    /// Position of the highlighted item in `order`. A new switch starts on the most recent item.
    public private(set) var index: Int

    /// The item the switcher is highlighting.
    public var selected: ID { order[index] }

    /// Returns nil for an empty order, because there is nothing to switch to.
    init?(order: [ID]) {
        guard !order.isEmpty else { return nil }
        self.order = order
        self.index = 0
    }

    /// Moves the highlight by `delta` items, wrapping at both ends. Tab steps forward (+1) and
    /// Shift+Tab steps back (-1). The first step from a fresh switch lands on the previous item.
    public mutating func step(_ delta: Int) {
        let count = order.count
        // Reduce the delta first so the addition cannot overflow for very large steps.
        index = (index + delta % count + count) % count
    }
}
