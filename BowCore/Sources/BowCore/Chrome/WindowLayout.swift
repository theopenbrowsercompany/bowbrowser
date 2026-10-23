import Foundation

/// Where a window keeps its tabs: in the sidebar (the default, as Arc does) or in a strip along the top, with the
/// navigation buttons, the URL field and the Space dots in one toolbar row below it. One app setting for every window.
/// The measurements are the maintainer's top tabs mockup, in points.
public enum WindowLayout: String, Sendable, CaseIterable {
    case sidebar
    case topTabs

    /// The layout a saved setting names; anything unknown or missing is the default, the sidebar layout.
    public init(stored: String?) {
        self = stored.flatMap(WindowLayout.init(rawValue:)) ?? .sidebar
    }

    /// The other layout.
    public var toggled: WindowLayout { self == .sidebar ? .topTabs : .sidebar }

    /// The tab strip row's height, the window buttons at its leading edge.
    public static let tabStripHeight: Double = 46
    /// The toolbar row's height, holding back, forward, reload, the URL field and the Space dots.
    public static let toolbarRowHeight: Double = 44
    /// The toolbar row's padding on each side, and the strip's before the window buttons.
    public static let rowPadding: Double = 14
    /// The gap between the toolbar row's items.
    public static let itemGap: Double = 14
    /// The URL field's height in the toolbar row.
    public static let urlFieldHeight: Double = 32
    /// The gap around the page card, which the card keeps in both layouts.
    public static let pageInset: Double = 8

    /// The menu item that switches to the other layout: "Use Top Tabs" in the sidebar layout, which carries a check
    /// while the top tabs layout is on.
    public static let menuTitle = "Use Top Tabs"

    /// The page card's insets from the window's content edges (top, leading, bottom, trailing) as measured from the
    /// content area's own edges: in the sidebar layout the card's leading edge meets the sidebar and the top has the
    /// inset only; in the top tabs layout the card sits under the strip and, while the toolbar shows, the toolbar row,
    /// with the inset on the other three sides.
    public func pageInsets(showsToolbar: Bool) -> (top: Double, leading: Double, bottom: Double, trailing: Double) {
        switch self {
        case .sidebar:
            return (Self.pageInset, 0, Self.pageInset, Self.pageInset)
        case .topTabs:
            let top = Self.tabStripHeight + (showsToolbar ? Self.toolbarRowHeight : Self.pageInset)
            return (top, Self.pageInset, Self.pageInset, Self.pageInset)
        }
    }
}
