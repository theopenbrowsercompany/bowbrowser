import AppKit
import BowCore

// The Peek area of the adapter: E2EPeekApp over the window's PeekFeature, which opens Peeks from the window's own
// popup and navigation paths, as it does outside a test.

extension E2ETestApp: E2EPeekApp {
    func peek(besides page: any E2EPage) throws -> E2EPeekState? {
        try adapter.requireActive(token, "read the window's Peek")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let peek = controller.feature(PeekFeature.self)?.peek else { return nil }
        let overlay = peek.overlay
        let area = controller.pageArea
        let panes = controller.paneViews
        // Above every pane: a later subview of the page area than each pane (or than the container holding them).
        let index = area.subviews.firstIndex(of: overlay)
        let overPanes =
            overlay.superview === area && index != nil
            && panes.allSatisfy { pane in
                let holder = area.subviews.firstIndex { pane === $0 || pane.isDescendant(of: $0) }
                return holder.map { $0 < index! } ?? true
            }
        let alpha = overlay.layer?.backgroundColor?.alpha ?? 0
        return E2EPeekState(
            title: peek.page.state.title, overPanes: overPanes, dimmed: alpha > 0 && !overlay.isHidden,
            isLoading: peek.page.state.isLoading,
            cardSize: overlay.webView.frame.size,
            showsPage: overlay.webView.isShowing(peek.page))
    }

    func untilPeek(besides page: any E2EPage) async throws -> any E2EPage {
        try adapter.requireActive(token, "wait for a Peek")
        let controller = try E2EAppAdapter.tabPage(page).controller
        var shown: (any EngineTab)?
        _ = try await E2EWaits.until {
            try adapter.requireActive(token, "wait for a Peek")
            shown = controller.feature(PeekFeature.self)?.peek?.page
            return shown != nil
        }
        guard let shown else { throw E2EError("the window showed no Peek") }
        return adapter.track(shown, in: controller, token: token)
    }

    func untilNoPeek(besides page: any E2EPage) async throws -> Bool {
        try adapter.requireActive(token, "wait for the Peek to close")
        let controller = try E2EAppAdapter.tabPage(page).controller
        return try await E2EWaits.until {
            try adapter.requireActive(token, "wait for the Peek to close")
            return controller.feature(PeekFeature.self)?.peek == nil
        }
    }

    func press(_ button: E2EPeekButton, besides page: any E2EPage) throws {
        try adapter.requireActive(token, "press the Peek's \(button.rawValue) button")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let overlay = controller.feature(PeekFeature.self)?.peek?.overlay else {
            throw E2EError("the window shows no Peek")
        }
        let control = button == .openAsTab ? overlay.openButton : overlay.closeButton
        guard control.window === controller.window, !control.isHiddenOrHasHiddenAncestor else {
            throw E2EError("the Peek's \(button.rawValue) button is not shown")
        }
        // The button's own action, as a click runs it (no tracking loop).
        control.performClick(nil)
    }

    func pressPeekBackdrop(besides page: any E2EPage) throws {
        try adapter.requireActive(token, "press the dimmed page around the Peek")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let overlay = controller.feature(PeekFeature.self)?.peek?.overlay else {
            throw E2EError("the window shows no Peek")
        }
        // The method the overlay's mouseDown calls, never a synthetic press into AppKit.
        overlay.pressBackdrop()
    }

    func setPeekSettings(shiftClick: Bool, offSiteLinks: Bool) throws {
        try adapter.requireActive(token, "change the Peek settings")
        AppSettings.peekSettings = PeekSettings(shiftClickOpensPeek: shiftClick, offSiteLinksOpenPeek: offSiteLinks)
    }

    func resetPeekSettings() {
        AppSettings.defaults.removeObject(forKey: AppSettings.peekShiftClickKey)
        AppSettings.defaults.removeObject(forKey: AppSettings.peekOffSiteLinksKey)
    }

    var peekOpenBrowsers: Int { adapter.openBrowserCount }
}
