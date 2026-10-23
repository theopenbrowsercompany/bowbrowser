import BowCore
import Foundation

/// What the Arc import wizard's sheet shows on a window (`E2EImportApp.importWizard(in:)`), read from its views.
struct E2EImportWizardState: Equatable, CustomStringConvertible {
    /// The step the sheet is on: consent, reading, failed, spaces, preview or done.
    var step: String
    /// Every label's text, top to bottom.
    var texts: [String]
    /// The titles of the buttons, left to right, each followed by "(off)" when disabled.
    var buttons: [String]
    /// Each checkbox as "title=on" or "title=off", top to bottom.
    var checkboxes: [String]
    /// The Space mode pop up's chosen title, nil when the step has none.
    var mode: String?
    /// The preview outline's rows as "depth:title", top to bottom, read from its cells.
    var tree: [String]

    var text: String { texts.joined(separator: " | ") }

    var description: String {
        "step=\(step) buttons=\(buttons) checkboxes=\(checkboxes) mode=\(mode ?? "none") tree=\(tree.count) rows"
            + " text=\(text)"
    }

    func hasButton(_ title: String) -> Bool { buttons.contains(title) }
}

/// A copy of a window's sidebar, to compare with later (`E2EImportApp.markSidebar(in:)`).
struct E2ESidebarMark {
    var graph: SidebarGraph
}

/// The Arc import wizard as a person uses it: File > Import from Arc…, the sheet's buttons and checkboxes, and what
/// the sheet and the sidebar show after each step. The file picker never opens: `useImportFile(_:)` answers it.
@MainActor
protocol E2EImportApp: E2EApp {
    /// Makes the file picker answer with the fixture `name` under E2E/Fixtures/import/ (a file in the app bundle)
    /// from now on, and counts its requests. The real picker never shows in an e2e run: with no file set it answers
    /// "cancelled".
    func useImportFile(_ name: String?) throws
    /// How many times the wizard asked the picker for a file since the run began.
    func importFileRequests() throws -> Int
    /// Chooses File > Import from Arc… in the window `page` is in, through the menu as a click does. Throws when the
    /// item is missing or disabled.
    func chooseImportMenuItem(in page: any E2EPage) throws
    /// Whether File > Import from Arc… is enabled in the window `page` is in, as its target validates it.
    func importMenuItemEnabled(in page: any E2EPage) throws -> Bool
    /// The wizard sheet on the window `page` is in; nil when no wizard sheet is up.
    func importWizard(in page: any E2EPage) throws -> E2EImportWizardState?
    /// Presses the enabled button called `title` in the wizard sheet (`performClick`). Throws when there is none.
    func pressImportButton(_ title: String, in page: any E2EPage) throws
    /// Ticks or unticks the checkbox called `title` in the wizard sheet. Throws when there is none.
    func setImportCheckbox(_ title: String, on: Bool, in page: any E2EPage) throws
    /// Chooses `title` in the wizard's Space mode pop up. Throws when there is none.
    func chooseImportMode(_ title: String, in page: any E2EPage) throws
    /// A copy of the window's sidebar as it is now.
    func markSidebar(in page: any E2EPage) throws -> E2ESidebarMark
    /// Whether the window's sidebar is exactly the marked copy: every Space, item, profile, the active Space and tab.
    func sidebarMatches(_ mark: E2ESidebarMark, in page: any E2EPage) throws -> Bool
    /// The rows the window's sidebar holds for every Space after the first `skipping` ones, then the Favorites of
    /// the default profile, as "depth:title" in the same form as the preview's rows: a Space is depth 0 with its
    /// pinned items below it, and the Favorites follow under "Favorites".
    func sidebarRows(skippingSpaces skipping: Int, in page: any E2EPage) throws -> [String]
    /// The titles of the window's Spaces, in order.
    func spaceTitles(in page: any E2EPage) throws -> [String]
    /// How many Favorites the default profile has, and the title of the Space on screen.
    func favoritesCount(in page: any E2EPage) throws -> Int
}
