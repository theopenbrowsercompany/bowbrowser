import Foundation

/// Where a newly opened tab goes.
public enum TabInsertion: Equatable, Sendable, Codable {
    /// Right after the active tab, or at the end when no tab is active.
    case afterActive
    case end
}

/// The ordered tabs of one window and which one is active.
///
/// Invariants, kept by every operation and checked when decoding: tab IDs are unique, and the active ID
/// is nil or names a tab in the list. An empty list has no active tab; a list with tabs may have none
/// too.
public struct TabList: Equatable, Sendable {
    public private(set) var tabs: [BrowserTab]
    public private(set) var activeID: BrowserTabID?

    public init() {
        self.tabs = []
        self.activeID = nil
    }

    /// Builds a list from saved tabs, with no active tab when `activeID` is nil. Returns nil when the
    /// IDs repeat or `activeID` is set but not in the tabs.
    public init?(tabs: [BrowserTab], activeID: BrowserTabID?) {
        guard Set(tabs.map(\.id)).count == tabs.count else { return nil }
        if let activeID {
            guard tabs.contains(where: { $0.id == activeID }) else { return nil }
        }
        self.tabs = tabs
        self.activeID = activeID
    }

    public var isEmpty: Bool { tabs.isEmpty }
    public var count: Int { tabs.count }

    public var activeTab: BrowserTab? {
        activeID.flatMap { tab(id: $0) }
    }

    public var activeIndex: Int? {
        activeID.flatMap { index(of: $0) }
    }

    public func index(of id: BrowserTabID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    public func tab(id: BrowserTabID) -> BrowserTab? {
        index(of: id).map { tabs[$0] }
    }

    /// Opens a tab. By default it becomes the active tab; pass `activate: false` for a background
    /// tab, which still becomes active when it is the list's only tab. Returns nil, changing nothing,
    /// when a tab with the same ID is already in the list.
    @discardableResult
    public mutating func open(
        _ tab: BrowserTab = BrowserTab(),
        at insertion: TabInsertion = .afterActive,
        activate: Bool = true
    ) -> BrowserTabID? {
        guard index(of: tab.id) == nil else { return nil }
        let position: Int
        switch insertion {
        case .afterActive: position = (activeIndex ?? tabs.count - 1) + 1
        case .end: position = tabs.count
        }
        tabs.insert(tab, at: position)
        // The first tab of an empty list is always active.
        if activate || tabs.count == 1 {
            activeID = tab.id
        }
        return tab.id
    }

    /// Closes a tab. Returns false when the ID is unknown.
    ///
    /// Closing a tab that is not active leaves the active tab alone (also when no tab is active).
    /// Closing the active tab selects the tab that was right after it, or the one before it when it
    /// was last. Closing the only tab leaves an empty list with no active tab.
    @discardableResult
    public mutating func close(_ id: BrowserTabID) -> Bool {
        guard let index = index(of: id) else { return false }
        tabs.remove(at: index)
        if activeID == id {
            if tabs.isEmpty {
                activeID = nil
            } else {
                activeID = tabs[min(index, tabs.count - 1)].id
            }
        }
        return true
    }

    /// Makes a tab active. Returns false when the ID is unknown.
    @discardableResult
    public mutating func select(_ id: BrowserTabID) -> Bool {
        guard index(of: id) != nil else { return false }
        activeID = id
        return true
    }

    /// Moves a tab so it ends up at `destination` in the resulting order (clamped to the list).
    /// The active tab stays the same tab. Returns false when the ID is unknown.
    @discardableResult
    public mutating func move(_ id: BrowserTabID, to destination: Int) -> Bool {
        guard let from = index(of: id) else { return false }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: max(0, min(destination, tabs.count)))
        return true
    }

    /// Applies an engine snapshot to a tab. Returns false when the ID is unknown.
    @discardableResult
    public mutating func update(_ id: BrowserTabID, from state: EngineTabState) -> Bool {
        guard let index = index(of: id) else { return false }
        tabs[index].apply(state)
        return true
    }
}

extension TabList: Codable {
    private enum CodingKeys: String, CodingKey {
        case tabs, activeID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tabs = try container.decode([BrowserTab].self, forKey: .tabs)
        let activeID = try container.decodeIfPresent(BrowserTabID.self, forKey: .activeID)
        guard let list = TabList(tabs: tabs, activeID: activeID) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Tab list is inconsistent"))
        }
        self = list
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(activeID, forKey: .activeID)
    }
}
