import AppKit
import BowCore

// The design area's frame surface: the app bundle's icon, the title bar, the sidebar's top row, the page card and
// its shadow, the frame color and the empty state.

extension E2EAppAdapter {
    static func frameLook(of controller: BrowserWindowController) throws -> E2EDesignFrameLook {
        guard let window = controller.window, let content = window.contentView else {
            throw E2EError("the window has closed")
        }
        let bundle = Bundle.main
        let iconName =
            bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        let resources = bundle.resourceURL
        let iconFileExists =
            iconName.flatMap { name in
                resources.map {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(name).icns").path)
                        && FileManager.default.fileExists(atPath: $0.appendingPathComponent("Assets.car").path)
                }
            } ?? false
        let sidebar = controller.e2eSidebar
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttonsOverSidebar = buttons.allSatisfy { type in
            guard let button = window.standardWindowButton(type) else { return false }
            let frame = button.convert(button.bounds, to: nil)
            return frame.minX >= sidebarFrame.minX && frame.maxX <= sidebarFrame.maxX
        }
        let navigation = controller.e2eNavigationToolbar
        let navigationFrames = NavigationToolbar.Item.allCases.map { item -> NSRect in
            let button = navigation.button(item)
            return button.window === window ? button.convert(button.bounds, to: nil) : .zero
        }
        let zoom = window.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
        let navigationInRow = navigationFrames.allSatisfy { frame in
            frame.minX > zoom.maxX && frame.maxX <= sidebarFrame.maxX && abs(frame.midY - zoom.midY) <= 2
        }
        let pageArea = controller.pageArea
        let pageLayer = pageArea.layer
        // Hit testing from the window's frame view, above the title bar, as a click is routed.
        let pageInWindow = pageArea.convert(pageArea.bounds, to: nil)
        let topPoint = NSPoint(x: pageInWindow.midX, y: pageInWindow.maxY - 4)
        let pageTopClickable =
            content.superview?.hitTest(topPoint).map { $0 === pageArea || $0.isDescendant(of: pageArea) } ?? false
        let shadowView = controller.pageShadowContainer
        let shadowLayer = shadowView?.layer
        let insets = controller.pageInsets
        let empty = controller.e2eEmptySpace
        let emptyShown = !empty.isHiddenOrHasHiddenAncestor && empty.window != nil
        // The start screen's mark for an empty Space, the unloaded tab state's mark otherwise.
        let emptyMark = emptyShown ? (empty.showsUnloadedTab ? empty.markView : empty.startScreen.markView) : nil
        return E2EDesignFrameLook(
            iconName: iconName,
            iconFileExists: iconFileExists,
            fullSizeContent: window.styleMask.contains(.fullSizeContentView),
            titlebarTransparent: window.titlebarAppearsTransparent,
            hasToolbar: window.toolbar != nil,
            sidebarWidth: Double(sidebar.frame.width),
            windowButtonsOverSidebar: buttonsOverSidebar,
            navigationInSidebarRow: navigationInRow,
            navigationDark: navigation.backButton.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            pageInsets: [insets.top, insets.left, insets.bottom, insets.right].map { Double($0) },
            pageCornerRadius: Double(pageLayer?.cornerRadius ?? 0),
            pageCornerContinuous: pageLayer?.cornerCurve == .continuous,
            pageTopClickable: pageTopClickable,
            pageShadowOpacity: Double(shadowView?.shadow?.shadowColor?.alphaComponent ?? 0),
            pageShadowRadius: Double(shadowView?.shadow?.shadowBlurRadius ?? 0),
            pageShadowHasPath: shadowLayer?.shadowPath.map { $0.boundingBox.size == shadowView?.bounds.size } ?? false,
            pageFrame: pageArea.frame,
            shadowFrame: shadowView?.frame ?? .zero,
            frameColor: designHex(window.backgroundColor, in: window.effectiveAppearance),
            showsEmptyState: emptyShown,
            emptyStateMarkSize: emptyMark.flatMap { $0.image == nil ? nil : Double($0.frame.width) } ?? 0)
    }
}
