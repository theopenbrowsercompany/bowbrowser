import AppKit
import BowCore

// The page fullscreen area of the adapter: E2EFullscreenApp over the window's PageFullscreenFeature, its chrome
// (SidebarFeature, TopTabsLayoutFeature) and the page container.

extension E2ETestApp: E2EFullscreenApp {
    func recordWindowFullScreen(of page: any E2EPage, startingFullScreen: Bool) throws {
        try adapter.requireActive(token, "record the window's full screen")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let recorder = E2EWindowFullScreenRecorder(window: controller.window, isFullScreen: startingFullScreen)
        try Self.fullscreenFeature(of: controller).e2eReplaceWindowFullScreen(recorder)
    }

    func fullscreenState(of page: any E2EPage) throws -> E2EFullscreenState {
        try adapter.requireActive(token, "read page fullscreen")
        let controller = try E2EAppAdapter.tabPage(page).controller
        let feature = try Self.fullscreenFeature(of: controller)
        guard let recorder = feature.fullScreen as? E2EWindowFullScreenRecorder else {
            throw E2EError("the window's full screen is not recorded")
        }
        let sidebar = controller.feature(SidebarFeature.self)
        let bar = controller.feature(TopTabsLayoutFeature.self)?.strip
        let insets = controller.pageInsets
        return E2EFullscreenState(
            pageFills: feature.isActive,
            sidebarHidden: (sidebar?.isHidden ?? true) && (sidebar?.sidebar.isHiddenOrHasHiddenAncestor ?? true),
            topBarShown: bar.map { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil } ?? false,
            pageInsets: [insets.top, insets.left, insets.bottom, insets.right].map { Double($0) },
            pageRadius: Double(controller.pageCornerRadius),
            hasShadow: controller.pageShadow != nil && controller.pageShadowContainer?.superview != nil,
            toggles: recorder.toggles, windowFullScreen: recorder.isFullScreen)
    }

    func leaveWindowFullScreen(of page: any E2EPage) throws {
        try adapter.requireActive(token, "leave the window's full screen")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let recorder = try Self.fullscreenFeature(of: controller).fullScreen as? E2EWindowFullScreenRecorder
        else { throw E2EError("the window's full screen is not recorded") }
        recorder.systemExit()
    }

    private static func fullscreenFeature(of controller: BrowserWindowController) throws -> PageFullscreenFeature {
        guard let feature = controller.feature(PageFullscreenFeature.self) else {
            throw E2EError("the window has no page fullscreen feature")
        }
        return feature
    }
}

/// Stands in for a window's macOS full screen: a toggle flips its state and counts, and leaving posts the window's
/// did exit full screen notification as the system does once the window is out.
@MainActor
final class E2EWindowFullScreenRecorder: WindowFullScreen {
    private weak var window: NSWindow?
    private(set) var isFullScreen: Bool
    private(set) var toggles = 0

    init(window: NSWindow?, isFullScreen: Bool) {
        self.window = window
        self.isFullScreen = isFullScreen
    }

    func toggle() {
        toggles += 1
        isFullScreen.toggle()
        if !isFullScreen { postExit() }
    }

    /// The system takes the window out of full screen (the green button), not through `toggle()`.
    func systemExit() {
        guard isFullScreen else { return }
        isFullScreen = false
        postExit()
    }

    private func postExit() {
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
    }
}
