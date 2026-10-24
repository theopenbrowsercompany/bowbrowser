import Foundation

/// The window frame's part of `E2EDesignLook`: the app icon in the bundle, the title bar, the sidebar's top row,
/// the page card and its shadow, the frame color and what the page area shows when it shows no page. Read by
/// E2E/Harness/E2EAppAdapter+DesignFrame.swift.
struct E2EDesignFrameLook {
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
    /// The empty state: shown, and its Bow mark's point size (0 without one).
    var showsEmptyState: Bool
    var emptyStateMarkSize: Double
}
