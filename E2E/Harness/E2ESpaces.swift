import Foundation

/// A window's Spaces as a test sees them (`E2ESpacesApp.spaces(of:)`).
struct E2ESpacesState: Equatable, CustomStringConvertible {
    /// Every browser window the app has open, so a test can see that switching opened none.
    var windows: Int
    /// The Spaces' names, in order.
    var spaces: [String]
    /// The name of the Space on screen.
    var active: String
    /// The tabs the sidebar lists for the Space on screen, pinned then today, by title (Favorites left out).
    var tabs: [String]
    /// The Space name the sidebar's header shows.
    var header: String
    /// The Space icons the sidebar's footer shows, by name, with "*" after the highlighted one.
    var footer: [String]

    var description: String {
        "windows=\(windows) spaces=[\(spaces.joined(separator: ","))] active=\(active) "
            + "tabs=[\(tabs.joined(separator: ","))] header=\(header) footer=[\(footer.joined(separator: ","))]"
    }
}

/// A sideways two-finger swipe on the sidebar, as `E2ESpacesApp.swipeSidebar(_:in:)` hands it to the sidebar's swipe
/// handler.
enum E2ESwipe: CustomStringConvertible {
    /// Fingers moving left, towards the next Space.
    case towardsNext
    /// Fingers moving right, towards the previous Space.
    case towardsPrevious

    var description: String {
        switch self {
        case .towardsNext: "towards-next"
        case .towardsPrevious: "towards-previous"
        }
    }
}

/// Spaces as a test drives them: reading the sidebar's Spaces, the switcher's "+" button, the questions Spaces ask
/// in a sheet, and the sidebar's swipe handler. Menu items go through `E2EMenuApp` and `chooseSpacesMenuItem`.
@MainActor
protocol E2ESpacesApp: E2EMenuApp {
    /// The Spaces of the window `page` is in, as its sidebar store and sidebar show them.
    func spaces(of page: any E2EPage) throws -> E2ESpacesState
    /// Clicks the "+" button in the sidebar's Space switcher of the window `page` is in.
    func clickNewSpaceButton(in page: any E2EPage) throws
    /// Chooses View > Spaces > `title` (such as "New Space" or "Delete Space…") in the window `page` is in, as
    /// clicking it does when that window is key. Throws when the item is missing or disabled.
    func chooseSpacesMenuItem(_ title: String, in page: any E2EPage) throws
    /// The message of the sheet on the window `page` is in, nil when no sheet is up.
    func sheetMessage(in page: any E2EPage) throws -> String?
    /// Answers the sheet on the window `page` is in: types `text` into its field first when given, then clicks its
    /// button titled `button`. Throws when no sheet is up or it has no such button or field.
    func answerSheet(_ button: String, text: String?, in page: any E2EPage) throws
    /// Hands the sidebar's swipe handler of the window `page` is in a whole swipe (began, changed, ended) moving
    /// `swipe`'s way by `distance` points, as the sidebar does for a trackpad swipe. A real trackpad gesture cannot
    /// be synthesized, so this drives the handler the sidebar connects its scroll view to. Throws when the sidebar
    /// has no swipe handler.
    func swipeSidebar(_ swipe: E2ESwipe, distance: Double, in page: any E2EPage) throws
}
