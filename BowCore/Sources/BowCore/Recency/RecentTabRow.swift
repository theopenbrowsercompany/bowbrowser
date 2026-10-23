import Foundation

extension SpaceSummary {
    /// The Space as one line of text next to a tab: its emoji (a symbol icon needs an image, so it shows the name
    /// alone) and its name, "💼 Work". The command bar and the Ctrl+Tab switcher both show it.
    public var label: String {
        let emoji = icon.flatMap { $0.kind == .emoji ? $0.value : nil }
        return [emoji, name].compactMap { $0 }.joined(separator: " ")
    }
}

/// One line of the Ctrl+Tab switcher's overlay: the data the app draws for a tab.
public struct RecentTabRow: Equatable, Sendable {
    public var item: SidebarItemID
    public var title: String
    /// The Space holding the tab, nil for a Favorite.
    public var space: SpaceSummary?

    public init(item: SidebarItemID, title: String, space: SpaceSummary?) {
        self.item = item
        self.title = title
        self.space = space
    }
}

extension RecencyList where ID == SidebarItemID {
    /// Drops the listed items that are not in `open`, and adds every item of `open` the list does not hold at its
    /// least recent end, in the order `open` gives them. A tab that was never shown (another Space's tab that has
    /// not loaded) is then still reachable from the switcher, after the ones used.
    public mutating func sync(open: [SidebarItemID]) {
        let openSet = Set(open)
        var order = ids.filter { openSet.contains($0) }
        let listed = Set(order)
        order += open.filter { !listed.contains($0) }
        var fresh = RecencyList(maxCount: maxCount)
        for id in order.reversed() { fresh.use(id) }
        self = fresh
    }
}
