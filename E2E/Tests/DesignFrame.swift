import Foundation

/// The window frame: the app icon in the bundle, one Frame colored surface under a transparent title bar with no
/// toolbar, the navigation buttons in the sidebar's top row beside the window buttons, the page as a card with
/// rounded corners and a soft shadow that follows a resize, and the brand fonts registered from the bundle.
@MainActor
enum DesignFrameTests {
    static let all: [any E2ETest] = [DesignFrameTest()]
}

struct DesignFrameTest: E2ETest {
    let name = "design.frame"
    let tags = ["smoke"]
    let checks = [
        "design.app_icon", "design.title_bar", "design.sidebar_top_row", "design.page_card", "design.page_shadow",
        "design.frame_color", "design.shadow_follows_resize", "design.fonts_registered",
    ]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let fonts = run.app as? any E2EFontsApp else { throw E2EError("the app has no font hooks") }
        let page = try await DesignTests.openBrowsing(run)
        let read = try await run.step("read the look", timeout: E2ETimeouts.step) {
            (try design.look(of: page).frame, try fonts.fonts(of: page))
        }
        let look = read.0
        run.check(
            "design.app_icon", passed: look.iconName == "AppIcon" && look.iconFileExists,
            "icon=\(look.iconName ?? "none") file=\(look.iconFileExists)")
        run.check(
            "design.title_bar",
            passed: look.fullSizeContent && look.titlebarTransparent && !look.hasToolbar
                && look.windowButtonsOverSidebar,
            "full_size=\(look.fullSizeContent) transparent=\(look.titlebarTransparent) toolbar=\(look.hasToolbar)"
                + " buttons_over_sidebar=\(look.windowButtonsOverSidebar)")
        run.check(
            "design.sidebar_top_row", passed: look.sidebarWidth == 264 && look.navigationInSidebarRow,
            "sidebar_width=\(look.sidebarWidth) navigation_in_row=\(look.navigationInSidebarRow)")
        run.check(
            "design.page_card",
            passed: look.pageInsets == [8, 0, 8, 8] && look.pageCornerRadius == 10 && look.pageCornerContinuous
                && look.pageTopClickable,
            "insets=\(look.pageInsets) radius=\(look.pageCornerRadius) continuous=\(look.pageCornerContinuous)"
                + " top_clickable=\(look.pageTopClickable)")
        run.check(
            "design.page_shadow",
            passed: look.pageShadowOpacity > 0 && look.pageShadowOpacity < 0.3 && look.pageShadowRadius > 0
                && look.pageShadowHasPath && look.shadowFrame == look.pageFrame,
            "opacity=\(look.pageShadowOpacity) radius=\(look.pageShadowRadius) path=\(look.pageShadowHasPath)"
                + " page=\(look.pageFrame) shadow=\(look.shadowFrame)")
        run.check(
            "design.frame_color", passed: look.frameColor == DesignTests.frameLight,
            "frame=\(look.frameColor ?? "none")")

        let browsing = read.1
        run.check(
            "design.fonts_registered",
            passed: browsing.nunitoRegistered && browsing.nunitoFromApp && browsing.fredokaRegistered
                && !browsing.jetBrainsPresent
                && browsing.fontFilesBundled && browsing.licenseFilesBundled
                && browsing.uiToken == E2EFontInfo(family: "Nunito Sans", name: browsing.uiToken.name, size: 13.5)
                && browsing.displayToken.family == "Fredoka" && browsing.displayToken.name.contains("SemiBold")
                && browsing.displayToken.size == 40,
            "nunito=\(browsing.nunitoRegistered) from_app=\(browsing.nunitoFromApp) fredoka=\(browsing.fredokaRegistered)"
                + " jetbrains=\(browsing.jetBrainsPresent) files=\(browsing.fontFilesBundled)"
                + " licenses=\(browsing.licenseFilesBundled) ui=\(browsing.uiToken) display=\(browsing.displayToken)")

        let resized = try await run.step("resize the window", timeout: E2ETimeouts.step) {
            try design.resizeWindow(of: page, width: 900, height: 600)
            _ = try await E2EWaits.until {
                let now = try design.look(of: page).frame
                return now.pageFrame.width != look.pageFrame.width && now.shadowFrame == now.pageFrame
            }
            return try design.look(of: page).frame
        }
        run.check(
            "design.shadow_follows_resize",
            passed: resized.pageFrame.width != look.pageFrame.width && resized.shadowFrame == resized.pageFrame
                && resized.pageShadowHasPath,
            "before=\(look.pageFrame) page=\(resized.pageFrame) shadow=\(resized.shadowFrame)"
                + " path=\(resized.pageShadowHasPath)")
    }
}
