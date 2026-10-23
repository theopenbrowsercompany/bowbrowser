import BowCore
import CoreGraphics
import Foundation

/// Air Traffic Control as a test sees it: the routing rules, links from other apps delivered as GetURL Apple Events
/// to the app's own handler (as in the links area), where each one opened, and the rule editor.
/// E2E/Harness/E2EAppAdapter+Routing.swift implements it; every action is refused once the test has ended, and the
/// rules, the editor and the sender's stand-in app go back to the run's own (the initial rules, no editor, Bow itself)
/// when the test ends.
///
/// A real sender other than Bow cannot be faked: the system names the process that sent an Apple Event. So links are
/// sent from Bow through the real Apple Event path, the app reads the sender (its PID, then its app) as for any link,
/// and `sendLinks(as:)` names the app Bow's bundle identifier stands for in routing (the app's `e2eSourceRenames`
/// seam).
@MainActor
protocol E2ERoutingApp: E2EApp {
    /// Replaces the routing rules through the app's own save path.
    func setRoutingTable(_ table: RoutingTable) throws
    /// The rules as the next launch reads them: a new Air Traffic Control service on the same data folder.
    func reloadedRoutingTable() throws -> RoutingTable
    /// The rules in use now.
    func routingTable() throws -> RoutingTable
    /// From now until the test ends, links Bow sends count as sent by the app with `bundleID` (nil: Bow itself).
    func sendLinks(as bundleID: String?) throws
    /// Delivers `url` as a GetURL Apple Event sent from this app to its own handler, the way a link clicked in
    /// another app arrives, and returns where it opened.
    func deliverRoutedLink(_ url: URL) throws -> E2ERoutedLink
    /// Hands `url` to the app's link opening path (the method the GetURL handler calls) as a link sent by a helper
    /// process of this app (Chromium's renderer). Returns the helper's bundle identifier and where the link opened,
    /// or nil when this app runs no helper.
    func deliverLinkFromHelper(_ url: URL) throws -> (helper: String, opened: E2ERoutedLink)?
    /// Bow's bundle identifier, which a link the harness sends comes from.
    var routingAppBundleID: String { get }
    /// Chooses Bow > Air Traffic Control… with `page`'s window in front, as a person opens the rule editor.
    func openRoutingEditor(from page: any E2EPage) throws
    /// The open rule editor as a person sees it, or nil when it is not open.
    func routingEditor() throws -> E2ERoutingEditorState?
    /// Selects rule `row` in the editor and clicks its Move Down button.
    func moveRuleDownInEditor(row: Int) throws
    /// Starts editing rule `row`'s text cell (0 match, 1 text, 2 app) in the field editor, as a click does, and types
    /// `text` over what it holds. It does not press Return or leave the cell.
    func typeInEditorCell(row: Int, column: Int, text: String) throws
    /// Moves focus to rule `row`'s destination pop-up, as a click on it does, which ends any edit in a text cell.
    func focusEditorDestination(row: Int) throws
    /// Clicks the editor's close button. Returns once it has closed.
    func closeRoutingEditor() throws
    /// How many browsers the engine has open or is creating, popups and Little Arc pages included.
    var routingOpenBrowsers: Int { get }
}

/// Where a link opened: a tab in a browser window, or a Little Arc window.
@MainActor
struct E2ERoutedLink {
    /// The new page, in a browser window or in Little Arc.
    var page: (any E2EPage)?
    /// The title of the Space the browser window shows with the new tab, nil for Little Arc.
    var spaceTitle: String?
    /// The engine profile the new page was created in.
    var profileID: String?
    /// True when the link opened a new Little Arc window.
    var littleArc: Bool

    /// "work" for a tab in Space Work, "little-arc", or "nowhere".
    var place: String {
        if littleArc { return "little-arc" }
        return spaceTitle?.lowercased() ?? "nowhere"
    }
}

/// The rule editor as it is now.
struct E2ERoutingEditorState: Equatable {
    /// Each rule's row as shown, cell by cell: match, text, source app, destination.
    var rows: [[String]]
    /// The line naming the app the last link came from.
    var lastSourceLine: String
    /// The "when no rule matches" pop-up's title.
    var defaultTitle: String
    /// True when the window is key or overlaps any screen; an e2e window must never.
    var intrudes: Bool
    var frame: CGRect
    var isKey: Bool
}
