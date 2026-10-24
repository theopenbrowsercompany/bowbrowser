import Foundation

/// The window's look as a test reads it, one part per surface (`E2EDesignLook`), plus window size and appearance
/// changes, the design fixture's clock and captures for the maintainer. E2E/Harness/E2EAppAdapter+Design.swift
/// implements it, with each surface's reading in its own `E2EAppAdapter+Design<Surface>.swift`; every action is
/// refused once the test has ended.
@MainActor
protocol E2EDesignApp: E2EApp {
    /// What `page`'s window and the app bundle look like now. Colors are read in the window's own appearance.
    func look(of page: any E2EPage) throws -> E2EDesignLook
    /// Resizes `page`'s window to `width` by `height` points, keeping its origin.
    func resizeWindow(of page: any E2EPage, width: Double, height: Double) throws
    /// Gives `page`'s window the dark appearance, or the light one when `dark` is false.
    func setDarkAppearance(_ dark: Bool, of page: any E2EPage) throws
    /// Removes the saved window layout (View > Use Top Tabs), so a test that switched it and back leaves the app's
    /// settings as it found them (no layout saved, which is the sidebar).
    func forgetWindowLayout() throws
    /// Writes a PNG of `page`'s window to `url` (title bar, sidebar, page card and web content), also when the
    /// window shows no page (the empty state), in which case the web content is left out.
    func writeScreenshot(of page: any E2EPage, to url: URL) async throws
    /// A design capture of `page`'s window as PNG data, at 2 pixels per point on any screen: the whole window with
    /// the tab it shows now (`window`), or only the sidebar's column from the window's top to its bottom, with no web
    /// content (`sidebar`). Before drawing it moves the pointer off the sidebar (every row, tile and button shows
    /// no hover) and hides the text caret, which it shows again after.
    func capture(of page: any E2EPage, _ region: E2EDesignRegion) async throws -> Data
    /// Makes the start screen's greeting read `date` as the time of day, or the real clock again with nil. The
    /// runner goes back to the real clock when the test ends.
    func useClock(_ date: Date?) throws
    /// The Spaces, Favorites and tabs `page`'s window holds, as the design fixture checks them.
    func fixtureState(of page: any E2EPage) throws -> E2EDesignFixtureState
}

/// What `E2EDesignApp.capture(of:_:)` draws.
enum E2EDesignRegion {
    case window
    case sidebar
}

/// The window's look (`E2EDesignApp.look(of:)`), one part per surface, each declared in its own
/// `E2EDesign<Surface>.swift`. Colors are `#RRGGBB` in sRGB, nil when there is none.
struct E2EDesignLook {
    var frame: E2EDesignFrameLook
    var sidebar: E2EDesignSidebarLook
    var favorites: E2EDesignFavoritesLook
    var footer: E2EDesignFooterLook
    var commandBar: E2EDesignCommandBarLook
}
