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
