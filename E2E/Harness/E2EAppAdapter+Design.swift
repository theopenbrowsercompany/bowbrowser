import AppKit
import BowCore

// The design area of the adapter: E2EDesignApp over the app bundle, the window, its page container, the page
// shadow, the sidebar's active row and the empty state.

extension E2ETestApp: E2EDesignApp {
    func look(of page: any E2EPage) throws -> E2EDesignLook {
        try adapter.requireActive(token, "read the window's look")
        return try E2EAppAdapter.look(of: E2EAppAdapter.tabPage(page).controller)
    }

    func resizeWindow(of page: any E2EPage, width: Double, height: Double) throws {
        try adapter.requireActive(token, "resize the window")
        guard let window = try E2EAppAdapter.tabPage(page).controller.window else {
            throw E2EError("the page has no window")
        }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: height)), display: true)
    }

    func setDarkAppearance(_ dark: Bool, of page: any E2EPage) throws {
        try adapter.requireActive(token, "change the window's appearance")
        try E2EAppAdapter.tabPage(page).controller.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    func writeScreenshot(of page: any E2EPage, to url: URL) async throws {
        try adapter.requireActive(token, "take a screenshot")
        let png: Data
        if page.contentView != nil {
            png = try await E2EScreenshot.png(page)
        } else {
            guard let window = try E2EAppAdapter.tabPage(page).controller.window else {
                throw E2EError("the page has no window")
            }
            png = try E2EScreenshot.png(window: window)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}

extension E2EAppAdapter {
    static func look(of controller: BrowserWindowController) throws -> E2EDesignLook {
        guard let window = controller.window, let content = window.contentView else {
            throw E2EError("the window has closed")
        }
        content.layoutSubtreeIfNeeded()
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
        let pageArea = controller.pageArea
        let pageLayer = pageArea.layer
        let shadowView = controller.feature(WindowLookFeature.self)?.shadowView
        let shadowLayer = shadowView?.layer
        let insets = controller.pageInsets
        let rowView = controller.tabList.activeID
            .flatMap { controller.sidebarItemID(for: $0) }
            .flatMap { sidebar.rowView(for: $0) }
        let liftLayer = (rowView?.superview as? SidebarRowView)?.liftView.layer
        let empty = controller.e2eEmptySpace
        let emptyShown = !empty.isHiddenOrHasHiddenAncestor && empty.window != nil
        let appearance = window.effectiveAppearance
        return E2EDesignLook(
            iconName: iconName,
            iconFileExists: iconFileExists,
            fullSizeContent: window.styleMask.contains(.fullSizeContentView),
            titlebarTransparent: window.titlebarAppearsTransparent,
            windowButtonsOverSidebar: buttonsOverSidebar,
            toolbarDark: controller.e2eNavigationToolbar.backButton.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
            titleBarHeight: Double(content.frame.height - window.contentLayoutRect.maxY),
            pageInsets: [insets.top, insets.left, insets.bottom, insets.right].map { Double($0) },
            pageCornerRadius: Double(pageLayer?.cornerRadius ?? 0),
            pageCornerContinuous: pageLayer?.cornerCurve == .continuous,
            pageShadowOpacity: Double(shadowLayer?.shadowOpacity ?? 0),
            pageShadowRadius: Double(shadowLayer?.shadowRadius ?? 0),
            pageShadowHasPath: shadowLayer?.shadowPath.map { $0.boundingBox.size == shadowView?.bounds.size } ?? false,
            pageFrame: pageArea.frame,
            shadowFrame: shadowView?.frame ?? .zero,
            frameColor: hex(window.backgroundColor, in: appearance),
            selectedRowBackground: liftLayer?.backgroundColor.flatMap { NSColor(cgColor: $0) }.flatMap {
                hex($0, in: appearance)
            },
            selectedRowText: rowView.flatMap { hex($0.titleField.textColor, in: appearance) },
            selectedRowCornerRadius: Double(liftLayer?.cornerRadius ?? 0),
            showsEmptyState: emptyShown,
            emptyStateMarkSize: emptyShown && empty.markView.image != nil ? Double(empty.markView.frame.width) : 0
        )
    }

    /// `color` as `#RRGGBB` in sRGB, resolved in `appearance`.
    private static func hex(_ color: NSColor?, in appearance: NSAppearance) -> String? {
        guard let color else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let rgb = resolved else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}
