import Foundation

// The window chrome as a test sees it: the copied address on a private pasteboard and the confirmation over the page.
// E2E/Harness/E2EAppAdapter+Chrome.swift implements it; every action is refused once the test has ended.

/// A named, private pasteboard the window's Copy Current URL writes to in place of the general one, so a test never
/// reads or overwrites what the person running it copied.
@MainActor
protocol E2EChromePasteboard: AnyObject {
    /// Counts every write; a copy raises it.
    var changeCount: Int { get }
    /// The plain string on it, nil when there is none.
    var string: String? { get }
    /// The URL on it (as a URL, not a string), nil when there is none.
    var url: URL? { get }
    /// Frees the pasteboard; the window writes to the general one again only if given it, so call it last.
    func release()
}

/// The confirmation label a copy shows over `page`'s window.
struct E2EChromeConfirmation: Equatable {
    /// True while it is visible (not hidden, not faded out).
    var isShown: Bool
    var text: String
    /// How many confirmation views the window holds (always one: a second copy restarts it).
    var viewCount: Int
}

@MainActor
protocol E2EChromeApp: E2EApp {
    /// Points `page`'s window's copy at a new private pasteboard and returns it.
    func usePrivatePasteboard(of page: any E2EPage) throws -> any E2EChromePasteboard
    /// The confirmation of `page`'s window now.
    func confirmation(of page: any E2EPage) throws -> E2EChromeConfirmation
}

/// The sidebar's URL field of a window, as a test sees it.
struct E2EURLField: Equatable, CustomStringConvertible {
    /// The text it shows: the site, or the placeholder.
    var text: String
    /// True while it shows the placeholder rather than an address.
    var isPlaceholder: Bool
    /// True while it is on screen in the window (neither it nor anything holding it is hidden).
    var isShown: Bool
    /// True while the sidebar's top row (back, forward, reload) shows.
    var isTopRowShown: Bool
    /// Its size, in points.
    var size: CGSize
    /// True when it sits wholly below the top row and the window's close, minimize and zoom buttons.
    var isBelowTopRow: Bool

    var description: String {
        "text=\"\(text)\" placeholder=\(isPlaceholder) shown=\(isShown) top-row=\(isTopRowShown) "
            + "size=\(Int(size.width))x\(Int(size.height)) below-top-row=\(isBelowTopRow)"
    }
}

@MainActor
protocol E2EURLFieldApp: E2EApp {
    /// The URL field of `page`'s window now.
    func urlField(of page: any E2EPage) throws -> E2EURLField
    /// Clicks the middle of `page`'s window's URL field the way a person does: a mouse down and up at that point,
    /// sent to whatever the window has there. Throws when the field is hidden or something else is on top of it.
    func clickURLField(of page: any E2EPage) throws
    /// The title of the View menu's toolbar item now, validated as the menu bar does before it shows ("Hide Toolbar"
    /// or "Show Toolbar").
    func toolbarMenuTitle(of page: any E2EPage) throws -> String
    /// The saved toolbar setting, nil when nothing is saved (the default: shown).
    func savedShowsToolbar() throws -> Bool?
}
