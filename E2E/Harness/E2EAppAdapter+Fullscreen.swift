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
        let recorder = try Self.recorder(of: controller)
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
            toggles: recorder.toggles, windowFullScreen: recorder.isFullScreen,
            windowTransition: recorder.transition.map { $0 ? .entering : .exiting } ?? .none)
    }

    func leaveWindowFullScreen(of page: any E2EPage) throws {
        try adapter.requireActive(token, "leave the window's full screen")
        guard try Self.recorder(of: E2EAppAdapter.tabPage(page).controller).systemExit() else {
            throw E2EError("the window's full screen is not in full screen, or is in a transition")
        }
    }

    func failWindowFullScreenTransition(of page: any E2EPage) throws {
        try adapter.requireActive(token, "fail the window's full screen transition")
        guard try Self.recorder(of: E2EAppAdapter.tabPage(page).controller).failTransition() else {
            throw E2EError("the window's full screen is not in a transition")
        }
    }

    func holdWindowFullScreenTransitions(of page: any E2EPage) throws {
        try adapter.requireActive(token, "hold the window's full screen transitions")
        try Self.recorder(of: E2EAppAdapter.tabPage(page).controller).holdsTransitions = true
    }

    func finishWindowFullScreenTransition(of page: any E2EPage) throws {
        try adapter.requireActive(token, "finish the window's full screen transition")
        guard try Self.recorder(of: E2EAppAdapter.tabPage(page).controller).finishTransition() else {
            throw E2EError("the window's full screen is not in a transition")
        }
    }

    private static func fullscreenFeature(of controller: BrowserWindowController) throws -> PageFullscreenFeature {
        guard let feature = controller.feature(PageFullscreenFeature.self) else {
            throw E2EError("the window has no page fullscreen feature")
        }
        return feature
    }

    private static func recorder(of controller: BrowserWindowController) throws -> E2EWindowFullScreenRecorder {
        guard let recorder = try fullscreenFeature(of: controller).fullScreen as? E2EWindowFullScreenRecorder else {
            throw E2EError("the window's full screen is not recorded")
        }
        return recorder
    }
}

/// Stands in for a window's macOS full screen, posting the window's full screen notifications as the system does: a
/// toggle counts, posts will enter or will exit, and (unless transitions are held) takes the new state and posts did
/// enter or did exit at once. A held transition ignores further toggles, as macOS does, until `finishTransition()`.
@MainActor
final class E2EWindowFullScreenRecorder: WindowFullScreen {
    private weak var window: NSWindow?
    private(set) var isFullScreen: Bool
    private(set) var toggles = 0
    /// True to hold each transition until `finishTransition()`.
    var holdsTransitions = false
    /// The held transition: true entering, false exiting, nil none.
    private(set) var transition: Bool?

    init(window: NSWindow?, isFullScreen: Bool) {
        self.window = window
        self.isFullScreen = isFullScreen
    }

    func toggle() {
        toggles += 1
        guard transition == nil else { return }
        start(toward: !isFullScreen)
    }

    /// The system takes the window out of full screen (the green button), not through `toggle()`; false when the
    /// window is not in full screen or a transition is in progress.
    func systemExit() -> Bool {
        guard isFullScreen, transition == nil else { return false }
        start(toward: false)
        return true
    }

    /// Ends the held transition; false when none is in progress.
    func finishTransition() -> Bool {
        guard let target = transition else { return false }
        transition = nil
        end(at: target)
        return true
    }

    /// Ends the held transition as failed, telling the window's delegate the way AppKit does (it posts no
    /// notification for a failure); false when none is in progress.
    func failTransition() -> Bool {
        guard let target = transition, let window else { return false }
        transition = nil
        if target {
            window.delegate?.windowDidFailToEnterFullScreen?(window)
        } else {
            window.delegate?.windowDidFailToExitFullScreen?(window)
        }
        return true
    }

    private func start(toward fullScreen: Bool) {
        if holdsTransitions { transition = fullScreen }
        post(fullScreen ? NSWindow.willEnterFullScreenNotification : NSWindow.willExitFullScreenNotification)
        if !holdsTransitions { end(at: fullScreen) }
    }

    private func end(at fullScreen: Bool) {
        isFullScreen = fullScreen
        post(fullScreen ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification)
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: window)
    }
}
