import Foundation

/// The start screen an empty Space shows, as a test reads and uses it: its greeting with the hour the app chose it
/// for, the search pill, the quick links and the hint. E2E/Harness/E2EAppAdapter+StartScreen.swift implements it;
/// every action is refused once the test has ended.
@MainActor
protocol E2EStartScreenApp: E2EApp {
    /// The start screen of `page`'s window now.
    func startScreen(of page: any E2EPage) throws -> E2EStartScreenLook
    /// Clicks the search pill (an AppKit click on the button), failing when the start screen is not shown.
    func clickStartSearch(in page: any E2EPage) throws
    /// Clicks quick link `index` (0 is the first), failing when it is not shown.
    func clickQuickLink(_ index: Int, in page: any E2EPage) throws
    /// Adds a Favorite saved on `url` named `title` at the end of the Favorites of the profile the Space on screen
    /// uses, through the sidebar store, and returns its item ID.
    func addFavorite(title: String, url: URL, in page: any E2EPage) throws -> String
    /// Deletes Favorite `item` from the sidebar store.
    func deleteFavorite(_ item: String, in page: any E2EPage) throws
    /// Renames the Space on screen.
    func renameActiveSpace(_ title: String, in page: any E2EPage) throws
}

/// What `E2EStartScreenApp.startScreen(of:)` reads. Colors are `#RRGGBB` in sRGB, resolved in the screen's own
/// appearance; frames are in the start screen's coordinates (bottom left origin).
struct E2EStartScreenLook {
    var isShown: Bool
    var greeting: String
    /// The local hour the greeting was chosen for.
    var greetingHour: Int
    var greetingFont: E2EFontInfo?
    var greetingColor: String?
    var markSize: CGSize
    var hint: String
    var hintFont: E2EFontInfo?
    var hintColor: String?
    var pillFrame: CGRect
    var pillRadius: Double
    var pillFill: String?
    var pillBorder: String?
    var pillBorderWidth: Double
    var placeholder: String
    var placeholderFont: E2EFontInfo?
    /// The titles of the quick links on screen, in order (links left out for lack of room are not listed).
    var linkTitles: [String]
    /// The first link's frame (76 wide) and its tile's size, radius and fill; zero without links.
    var linkFrame: CGRect
    var tileSize: CGSize
    var tileRadius: Double
    var tileFill: String?
    var linkTitleFont: E2EFontInfo?
    /// The vertical gaps between the parts on screen, top to bottom.
    var gaps: [Double]
    /// The screen's bounds, and the union of its parts' frames (every part on screen must lie inside the bounds).
    var bounds: CGRect
    var contentFrame: CGRect
    /// Whether the appearance the screen draws in is dark.
    var drawsDark: Bool
}
