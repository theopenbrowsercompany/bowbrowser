import AppKit
import BowCore

// The page behavior area of the adapter: E2EPageBehaviorApp over the window's CrashedTabFeature and
// ContextMenuFeature, and the tab's zoom level.

extension E2ETestApp: E2EPageBehaviorApp {
    func zoomLevel(of page: any E2EPage) throws -> Double {
        try adapter.requireActive(token, "read the zoom level")
        return try E2EAppAdapter.tabPage(page).tab.zoomLevel
    }

    func crashedPage(of page: any E2EPage) throws -> E2ECrashedPage {
        try adapter.requireActive(token, "read the crashed tab page")
        let tabPage = try E2EAppAdapter.tabPage(page)
        let feature = try Self.crashedFeature(of: page)
        guard let view = feature.crashedView(covering: tabPage.tab) else {
            let unused = feature.crashedViews[0]
            return E2ECrashedPage(
                isShown: false, message: unused.messageLabel.stringValue, buttonTitle: unused.reloadButton.title,
                buttonReachable: false)
        }
        view.superview?.layoutSubtreeIfNeeded()
        return E2ECrashedPage(
            isShown: !view.isHiddenOrHasHiddenAncestor && view.window != nil,
            message: view.messageLabel.stringValue, buttonTitle: view.reloadButton.title,
            buttonReachable: Self.hitTarget(of: view.reloadButton) === view.reloadButton,
            frame: view.convert(view.bounds, to: nil))
    }

    func clickCrashedReload(of page: any E2EPage) throws {
        try adapter.requireActive(token, "click Reload on the crashed tab page")
        let tabPage = try E2EAppAdapter.tabPage(page)
        guard let view = try Self.crashedFeature(of: page).crashedView(covering: tabPage.tab) else {
            throw E2EError("the crashed tab page is not shown")
        }
        let button = view.reloadButton
        guard !view.isHiddenOrHasHiddenAncestor, button.window != nil else {
            throw E2EError("the crashed tab page is not shown")
        }
        guard Self.hitTarget(of: button) === button else { throw E2EError("something covers the Reload button") }
        // A button tracks a press until the release, so the click goes through its own press handling.
        button.performClick(nil)
    }

    func usePrivateImagePasteboard(of page: any E2EPage) throws -> any E2EImagePasteboard {
        try adapter.requireActive(token, "use a private pasteboard")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(ContextMenuFeature.self) else {
            throw E2EError("the window has no context menu feature")
        }
        let board = NSPasteboard(name: NSPasteboard.Name("bow.e2e.image.\(UUID().uuidString)"))
        board.clearContents()
        feature.pasteboard = board
        return PrivateImagePasteboard(board: board)
    }

    private static func crashedFeature(of page: any E2EPage) throws -> CrashedTabFeature {
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(CrashedTabFeature.self) else {
            throw E2EError("the window has no crashed tab feature")
        }
        return feature
    }

    private static func hitTarget(of button: NSView) -> NSView? {
        guard let content = button.window?.contentView, !button.isHiddenOrHasHiddenAncestor else { return nil }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        return content.superview?.hitTest(point) ?? content.hitTest(point)
    }
}

@MainActor
private final class PrivateImagePasteboard: E2EImagePasteboard {
    let board: NSPasteboard

    init(board: NSPasteboard) { self.board = board }

    var changeCount: Int { board.changeCount }
    var string: String? { board.string(forType: .string) }

    var imagePixelSize: CGSize? {
        guard let data = board.data(forType: .tiff) ?? board.data(forType: .png),
            let rep = NSBitmapImageRep(data: data)
        else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    func release() { board.releaseGlobally() }
}
