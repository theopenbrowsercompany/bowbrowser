import Foundation

/// What a test reads of the top tabs layout: the setting, the sidebar, the strip and toolbar rows, the URL field, the
/// Space dots and the page card (`E2ETopTabsApp.topTabs(of:)`). Sizes are points; frames are in window coordinates
/// measured from the window's top edge and leading edge.
struct E2ETopTabsState: Equatable, CustomStringConvertible {
    /// The saved layout setting, nil when none is saved (the default: the sidebar).
    var saved: String?
    /// The View menu item's title and whether it shows a check, as the menu validates it.
    var menuTitle: String
    var menuChecked: Bool
    var sidebarHidden: Bool
    /// The sidebar's leading edge from the window's, 0 while shown and negative (off the window) while hidden.
    var sidebarMinX: Double
    var barShown: Bool
    var stripHeight: Double
    var toolbarHeight: Double
    /// The toolbar row's items, in order, by name ("back", "forward", "reload", "url", "dots") with their frames.
    var items: [String: E2ETopFrame]
    var itemOrder: [String]
    /// The first item's leading edge and the last item's distance from the window's trailing edge.
    var leadingPadding: Double
    var trailingPadding: Double
    var navigationTint: String?
    var urlText: String
    var urlRadius: Double
    var urlFill: String?
    /// The dots: how many, the one on screen's ring width and the dot's drawn size, and its name.
    var dotCount: Int
    var activeDotRing: Double
    var dotSize: Double
    var activeDotName: String?
    /// The page card's distance from the window's top, leading, bottom and trailing edges, and its radius.
    var pageInsets: [Double]
    var pageRadius: Double
    /// The close button's leading edge and its middle's distance from the window's top edge.
    var closeButtonX: Double
    var closeButtonMidY: Double

    var description: String {
        let frames = itemOrder.map { name in "\(name)=\(items[name].map(\.description) ?? "none")" }
            .joined(separator: " ")
        return "saved=\(saved ?? "nil") menu=\"\(menuTitle)\" checked=\(menuChecked) sidebar-hidden=\(sidebarHidden) "
            + "sidebar-x=\(Int(sidebarMinX)) bar=\(barShown) strip=\(Int(stripHeight)) toolbar=\(Int(toolbarHeight)) "
            + "[\(frames)] padding=\(Int(leadingPadding))/\(Int(trailingPadding)) tint=\(navigationTint ?? "nil") "
            + "url=\"\(urlText)\" radius=\(Int(urlRadius)) fill=\(urlFill ?? "nil") dots=\(dotCount) "
            + "ring=\(Int(activeDotRing)) dot=\(Int(dotSize)) active-dot=\(activeDotName ?? "none") "
            + "page=\(pageInsets.map { Int($0) }) page-radius=\(Int(pageRadius)) "
            + "close=\(Int(closeButtonX)),\(Int(closeButtonMidY))"
    }
}

struct E2ETopFrame: Equatable, CustomStringConvertible {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var description: String { "\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height))" }
}

@MainActor
protocol E2ETopTabsApp: E2EStoreSeedApp, E2EMenuApp, E2ECommandBarApp, E2ESpacesApp {
    /// The window's layout state now.
    func topTabs(of page: any E2EPage) throws -> E2ETopTabsState
    /// Chooses View > Use Top Tabs in `page`'s window, after the item validates, as a click does.
    func chooseUseTopTabs(in page: any E2EPage) throws
    /// Clicks the toolbar row's `index`th Space dot (0 is the first) the way a person does. Throws when the row's
    /// dots are hidden or fewer.
    func clickTopSpaceDot(_ index: Int, in page: any E2EPage) throws
}
