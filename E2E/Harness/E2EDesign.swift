import Foundation

/// The window's look as a test reads it: the app icon in the bundle, the title bar style, the page card, the frame
/// color and the active row's colors, plus window size and appearance changes and screenshots for the maintainer.
/// E2E/Harness/E2EAppAdapter+Design.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EDesignApp: E2EApp {
    /// What `page`'s window and the app bundle look like now. Colors are read in the window's own appearance.
    func look(of page: any E2EPage) throws -> E2EDesignLook
    /// Resizes `page`'s window to `width` by `height` points, keeping its origin.
    func resizeWindow(of page: any E2EPage, width: Double, height: Double) throws
    /// Gives `page`'s window the dark appearance, or the light one when `dark` is false.
    func setDarkAppearance(_ dark: Bool, of page: any E2EPage) throws
    /// Writes a PNG of `page`'s window to `url` (title bar, sidebar, page card and web content), also when the
    /// window shows no page (the empty state), in which case the web content is left out.
    func writeScreenshot(of page: any E2EPage, to url: URL) async throws
}

/// The window's look (`E2EDesignApp.look(of:)`). Colors are `#RRGGBB` in sRGB, nil when there is none.
struct E2EDesignLook {
    /// The bundle's icon name (CFBundleIconName, else CFBundleIconFile), nil without one.
    var iconName: String?
    /// True when the compiled icon (`<name>.icns` and `Assets.car`) is in the app's Resources.
    var iconFileExists: Bool
    var fullSizeContent: Bool
    var titlebarTransparent: Bool
    /// True when the window's close, minimize and zoom buttons sit within the sidebar's width.
    var windowButtonsOverSidebar: Bool
    /// True when the toolbar's back button draws in the dark appearance, as it must when the window is dark.
    var toolbarDark: Bool
    /// The title bar's height, which the page card's top inset matches.
    var titleBarHeight: Double
    /// The page area's insets: top, left, bottom, right.
    var pageInsets: [Double]
    var pageCornerRadius: Double
    var pageCornerContinuous: Bool
    var pageShadowOpacity: Double
    var pageShadowRadius: Double
    /// True when the page shadow has a shadow path the size of its view.
    var pageShadowHasPath: Bool
    /// The page area's and the shadow view's frames, in the window's content view.
    var pageFrame: CGRect
    var shadowFrame: CGRect
    /// The window's background, which the frame (sidebar and title bar) shows.
    var frameColor: String?
    /// The active tab's row: its lifted background and its title color.
    var selectedRowBackground: String?
    var selectedRowText: String?
    var selectedRowCornerRadius: Double
    /// The empty state: shown, and its Bow mark's point size (0 without one).
    var showsEmptyState: Bool
    var emptyStateMarkSize: Double
}
