import Foundation

// Basic page behaviors as a test sees them: a page's zoom level, the crashed tab page and the image Copy Image puts on
// a private pasteboard. E2E/Harness/E2EAppAdapter+PageBehavior.swift implements it; every action is refused once the
// test has ended.

/// The crashed tab page over `page`'s window now.
struct E2ECrashedPage: Equatable, CustomStringConvertible {
    /// True while it is visible over the page area.
    var isShown: Bool
    var message: String
    var buttonTitle: String
    /// True when the button is on screen in the window (not hidden, with a window) and nothing covers its center.
    var buttonReachable: Bool
    /// The overlay's frame in window coordinates, zero while it covers no pane.
    var frame: CGRect = .zero

    var description: String {
        "shown=\(isShown) message=\"\(message)\" button=\"\(buttonTitle)\" reachable=\(buttonReachable)"
            + " frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
    }
}

/// A named, private pasteboard Copy Image writes to in place of the general one.
@MainActor
protocol E2EImagePasteboard: AnyObject {
    /// Counts every write; a copy raises it.
    var changeCount: Int { get }
    /// The size in pixels of the image on it, decoded from its image data, nil when there is none.
    var imagePixelSize: CGSize? { get }
    /// The plain string on it, nil when there is none.
    var string: String? { get }
    /// Frees the pasteboard; the window writes to the general one again only if given it, so call it last.
    func release()
}

@MainActor
protocol E2EPageBehaviorApp: E2EApp {
    /// The zoom level of `page`'s tab (0 is 100%), as the engine holds it for the tab's site.
    func zoomLevel(of page: any E2EPage) throws -> Double
    /// The crashed tab page of `page`'s window now.
    func crashedPage(of page: any E2EPage) throws -> E2ECrashedPage
    /// Clicks the crashed tab page's Reload button the way a person does: a click sent to whatever the window has at
    /// the button's center. Throws when the page is not shown or something else covers the button.
    func clickCrashedReload(of page: any E2EPage) throws
    /// Points `page`'s window's Copy Image at a new private pasteboard and returns it.
    func usePrivateImagePasteboard(of page: any E2EPage) throws -> any E2EImagePasteboard
}
