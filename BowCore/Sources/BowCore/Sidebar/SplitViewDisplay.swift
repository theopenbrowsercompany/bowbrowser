import Foundation

// How a window keeps its panes in step with the split views in its sidebar. A split is a sidebar item: selecting one
// of its tabs (or its row, which selects its focused tab) shows all of its tabs side by side, and selecting a tab
// outside it shows that tab alone. While a split shows, the window's own pane rules (`PaneLayout`) take a pane away
// when its tab closes or unloads; `SplitViewDisplay` accepts that rather than loading the tab again, and brings the
// panes back once the person selects a tab of the split that is not on screen.

/// The panes a split view shows: its tabs in pane order, the focused one, each pane's share and how the panes sit.
public struct SplitPanes: Equatable, Sendable {
    public var splitID: SidebarItemID
    public var panes: [SidebarItemID]
    public var focused: SidebarItemID
    public var fractions: [Double]
    /// Side by side (`.horizontal`) or stacked top to bottom (`.vertical`).
    public var orientation: SidebarSplit.Orientation

    public init(
        splitID: SidebarItemID, panes: [SidebarItemID], focused: SidebarItemID, fractions: [Double],
        orientation: SidebarSplit.Orientation = .horizontal
    ) {
        self.splitID = splitID
        self.panes = panes
        self.focused = focused
        self.fractions = fractions
        self.orientation = orientation
    }
}

/// What opening a tab in a split view beside the active tab does (`SidebarGraph.splitOpening(_:besides:)`).
public enum SplitOpening: Equatable, Sendable {
    /// Make a split of these tabs, in this order.
    case create([SidebarItemID])
    /// Add the tab to the split as its last pane.
    case addPane(SidebarItemID, to: SidebarItemID)
}

/// Which side of the shown tab a new pane opens on: Add Split View (Arc's Add Right Split) after the panes, to the
/// right side by side or at the bottom of a stacked split; Add Top Split above them and Add Bottom Split below them,
/// stacked.
public enum NewPaneEdge: Equatable, Sendable {
    case trailing
    case top
    case bottom

    /// The layout a new split made from this edge takes.
    public var orientation: SidebarSplit.Orientation {
        self == .trailing ? .horizontal : .vertical
    }
}

/// Where a new tab opened as a pane goes (`SidebarGraph.newPanePlacement(besides:edge:)`).
public enum NewPanePlacement: Equatable, Sendable {
    /// Into a new split with this tab, in its place, laid out as `orientation`; the new pane comes first when
    /// `newPaneFirst` (a top split), otherwise second.
    case createWith(SidebarItemID, orientation: SidebarSplit.Orientation, newPaneFirst: Bool)
    /// Into this split, as the pane at `index`.
    case addPane(to: SidebarItemID, at: Int)
}

/// Keeps a window's panes in step with the sidebar's split views. The window calls `update` after each change with
/// the sidebar and the tabs its panes show now, does what it answers, then tells `record` what its panes show.
public struct SplitViewDisplay: Equatable, Sendable {
    /// What the window does to its panes.
    public enum Action: Equatable, Sendable {
        /// Leave the panes as they are.
        case none
        /// Show these panes.
        case show(SplitPanes)
        /// Show this tab alone: the split the panes showed is gone or was left.
        case single(SidebarItemID)
    }

    /// The split the window shows as panes, nil while it shows none.
    public private(set) var splitID: SidebarItemID?
    /// The tabs the panes showed after the last change.
    public private(set) var shown: [SidebarItemID] = []
    /// The layout of the split the panes show.
    public private(set) var orientation: SidebarSplit.Orientation = .horizontal

    public init() {}

    /// What to do once the sidebar is `graph` and the panes show `shownNow` (pane order).
    ///
    /// - The active tab is a pane of a split: the split's panes show, unless they already do, or the split was on
    ///   screen, the active tab was among the panes, and the panes now show only tabs of the split (a pane left
    ///   because its tab closed or unloaded, which must not load it again).
    /// - Otherwise, when the panes showed a split and still show several tabs (it was separated, or a pane's tab left
    ///   it), the active tab shows alone. Panes that no split put there are left alone.
    public mutating func update(graph: SidebarGraph, shownNow: [SidebarItemID]) -> Action {
        guard let active = graph.activeTabID else {
            splitID = nil
            shown = shownNow
            return .none
        }
        if let plan = graph.splitPanes(showing: active) {
            let stayed =
                splitID == plan.splitID && shown.contains(active) && Set(shownNow).isSubset(of: plan.panes)
                && shownNow.contains(active)
            // The split's layout turned (side by side to stacked or back) while it showed: show it again.
            let turned = splitID == plan.splitID && orientation != plan.orientation
            splitID = plan.splitID
            orientation = plan.orientation
            if (shownNow == plan.panes || stayed) && !turned {
                shown = shownNow
                return .none
            }
            return .show(plan)
        }
        let showedSplit = splitID != nil
        splitID = nil
        shown = shownNow
        return showedSplit && shownNow.count > 1 ? .single(active) : .none
    }

    /// The panes show `shown` after the window did what `update` answered.
    public mutating func record(shown: [SidebarItemID]) {
        self.shown = shown
    }
}
