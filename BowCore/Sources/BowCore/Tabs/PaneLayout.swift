import Foundation

/// What a window's page area shows: one to four tabs side by side, each in its own pane, one of them focused. The
/// focused pane's tab is the window's active tab, so the sidebar, the toolbar, find and the keyboard all follow it.
///
/// The window keeps one layout while the person works in it and brings it up to date with `reconciled` after every
/// change: a pane whose tab can no longer be shown leaves and the others share its width, selecting a tab that is a
/// pane moves focus there, and selecting any other tab returns the page area to a single view of that tab.
public struct PaneLayout<ID: Hashable>: Equatable {
    public static var maximumPanes: Int { SidebarSplit.maximumPanes }

    /// The tabs in pane order, leading to trailing.
    public private(set) var tabs: [ID]
    /// The tab of the pane that has focus, always one of `tabs`.
    public private(set) var focused: ID
    /// Each pane's share of the page area's width, in pane order, summing to 1.
    public private(set) var fractions: [Double]

    /// A layout of `tabs` with `focused` in focus, or nil when there are not one to four tabs, a tab is listed twice,
    /// or `focused` is not one of them. `fractions` that do not fit (a count that does not match, a share that is not
    /// a positive number) give equal panes; a pane under `SidebarSplit.minimumPaneFraction` is raised to it.
    public init?(tabs: [ID], focused: ID, fractions: [Double]? = nil) {
        guard (1...Self.maximumPanes).contains(tabs.count), Set(tabs).count == tabs.count, tabs.contains(focused)
        else { return nil }
        self.tabs = tabs
        self.focused = focused
        self.fractions = Self.fitting(fractions, count: tabs.count)
    }

    /// One pane showing `tab`.
    public static func single(_ tab: ID) -> PaneLayout {
        PaneLayout(tabs: [tab], focused: tab)!
    }

    /// Whether the page area shows more than one pane.
    public var isSplit: Bool { tabs.count > 1 }

    /// The position of the focused pane among the panes.
    public var focusedIndex: Int { tabs.firstIndex(of: focused) ?? 0 }

    /// The layout once the window's active tab is `active` and only tabs for which `showable` is true can be shown:
    /// nil when no tab is active (the page area shows none); a single pane of `active` when it is not one of the
    /// panes; otherwise the panes that can still be shown, the active one always among them, with focus on `active`
    /// and the width of the panes that left shared among the rest in proportion.
    public func reconciled(active: ID?, showable: (ID) -> Bool) -> PaneLayout? {
        guard let active else { return nil }
        guard tabs.contains(active) else { return .single(active) }
        let kept = tabs.indices.filter { tabs[$0] == active || showable(tabs[$0]) }
        return PaneLayout(tabs: kept.map { tabs[$0] }, focused: active, fractions: kept.map { fractions[$0] })
    }

    /// The pane that takes focus when the tab of `tab`'s pane closes: the pane before it, or the one after it when it
    /// is the first. Nil when `tab` is not a pane or is the only one.
    public func focusAfterClosing(_ tab: ID) -> ID? {
        guard let index = tabs.firstIndex(of: tab), tabs.count > 1 else { return nil }
        return tabs[index > 0 ? index - 1 : 1]
    }

    private static func fitting(_ fractions: [Double]?, count: Int) -> [Double] {
        if let fractions, fractions.count == count, let normalized = SidebarSplit.normalized(fractions) {
            return SidebarSplit.keepingMinimum(normalized)
        }
        return Array(repeating: 1 / Double(count), count: count)
    }
}
