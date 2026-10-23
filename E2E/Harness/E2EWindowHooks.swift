import Foundation

/// The window's engine hooks as a test sees them: popups a page opens, taken into the window as sidebar tabs through
/// `BrowserWindowController.adoptTab`. E2E/Harness/E2EAppAdapter+WindowHooks.swift implements it; every action is
/// refused once the test has ended.
@MainActor
protocol E2EWindowHooksApp: E2EApp {
    /// From now on, every popup `page`'s page opens is decided as a foreground tab and adopted by `page`'s window
    /// right after `page`'s tab, the way a link handling feature takes it.
    func adoptPopups(of page: any E2EPage) throws
    /// The pages of the popups adopted so far from `page`, oldest first.
    func adoptedPages(of page: any E2EPage) throws -> [any E2EPage]
    /// The click modifiers of each popup request `page`'s page made so far, oldest first.
    func popupModifiers(of page: any E2EPage) throws -> [E2EClickModifiers]
    /// The titles of the rows of the Space on screen in `page`'s window, in sidebar order.
    func rowTitles(besides page: any E2EPage) throws -> [String]
}

/// The command and shift keys a popup request reports for its click.
struct E2EClickModifiers: Equatable, CustomStringConvertible {
    var command: Bool
    var shift: Bool

    var description: String {
        switch (command, shift) {
        case (true, true): "command+shift"
        case (true, false): "command"
        case (false, true): "shift"
        case (false, false): "none"
        }
    }
}
