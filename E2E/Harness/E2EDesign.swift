import Foundation

/// The window's look as a test reads it: the app icon in the bundle, the title bar style, the sidebar's top row,
/// the page card, the frame color and the active row, plus window size and appearance changes and screenshots for
/// the maintainer. E2E/Harness/E2EAppAdapter+Design.swift implements it; every action is refused once the test has
/// ended.
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
    /// True when the window has a toolbar.
    var hasToolbar: Bool
    var sidebarWidth: Double
    /// True when the window's close, minimize and zoom buttons sit within the sidebar's width.
    var windowButtonsOverSidebar: Bool
    /// True when the back, forward and reload buttons sit in the sidebar, after the window buttons and level with
    /// them (centers within 2 points).
    var navigationInSidebarRow: Bool
    /// True when the navigation buttons draw in the dark appearance, as they must when the window is dark.
    var navigationDark: Bool
    /// The page area's insets: top, left, bottom, right.
    var pageInsets: [Double]
    var pageCornerRadius: Double
    var pageCornerContinuous: Bool
    /// True when a click 4 points below the page card's top edge reaches the page, not the title bar.
    var pageTopClickable: Bool
    var pageShadowOpacity: Double
    var pageShadowRadius: Double
    /// True when the page shadow has a shadow path the size of its view.
    var pageShadowHasPath: Bool
    /// The page area's and the shadow view's frames, in the window's content view.
    var pageFrame: CGRect
    var shadowFrame: CGRect
    /// The window's background, which the frame (sidebar and title bar) shows.
    var frameColor: String?
    /// The active tab's row: its lifted background, its shadow opacity, its height, corner radius, and its title's
    /// color and weight.
    var selectedRowBackground: String?
    var selectedRowShadowOpacity: Double
    var selectedRowHeight: Double
    var selectedRowCornerRadius: Double
    var selectedRowText: String?
    var selectedRowBold: Bool
    /// The empty state: shown, and its Bow mark's point size (0 without one).
    var showsEmptyState: Bool
    var emptyStateMarkSize: Double
    /// Frames in the sidebar's outline (top left origin, x from the sidebar's leading edge), zero when not shown: the
    /// first Favorite tile, the Favorites grid, the Space name and the first row of the Space's tabs.
    var favoriteTileFrame: CGRect
    var favoritesFrame: CGRect
    var spaceNameFrame: CGRect
    var firstTabRowFrame: CGRect
    /// The leading x of the icon of the first tab directly in a section and of the first tab inside a folder, in the
    /// outline, and that second row's height; 0 without such a row.
    var topIconX: Double
    var childIconX: Double
    var childRowHeight: Double
    /// The active Space's dot in the footer: its size, its ring's width and color, and the gap between them.
    var spaceDotSize: Double
    var spaceRingWidth: Double
    var spaceRingGap: Double
    var spaceRingColor: String?
    /// The command bar's panel: the corner radius its content is clipped to, whether it is clipped, and whether the
    /// panel's shadow has a path the size of the panel (read while the bar shows).
    var commandBarRadius: Double
    var commandBarClips: Bool
    var commandBarShadowHasPath: Bool
}
