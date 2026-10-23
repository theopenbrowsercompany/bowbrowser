import AppKit
import BowCore

// The tab strip area of the adapter: E2ETabStripApp over the top tabs feature's strip view and its pills.

extension E2ETestApp: E2ETabStripApp {
    func tabStrip(of page: any E2EPage) throws -> E2ETabStripState {
        try adapter.requireActive(token, "read the tab strip")
        let (controller, feature, content) = try stripParts(of: page)
        content.layoutSubtreeIfNeeded()
        feature.tabs.layoutSubtreeIfNeeded()
        let appearance = controller.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        func frame(of view: NSView) -> E2ETopFrame {
            let rect = view.convert(view.bounds, to: content)
            return E2ETopFrame(
                x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let bold = BowBrand.ui(CGFloat(TabStripLayout.titleSize), weight: .bold).fontName
        let regular = BowBrand.ui(CGFloat(TabStripLayout.titleSize)).fontName
        let pills = feature.tabs.pills.map { pill in
            let font = pill.titleField.font
            let shadow = pill.shadow
            var shadowOpacity = 0.0
            appearance.performAsCurrentDrawingAppearance {
                shadowOpacity = Double(shadow?.shadowColor.flatMap { ($0 as? NSColor)?.alphaComponent } ?? 0)
            }
            return E2EStripPill(
                title: pill.titleField.stringValue, frame: frame(of: pill), isActive: pill.isActive,
                fill: Self.stripHex(pill.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }, in: appearance),
                radius: Double(pill.layer?.cornerRadius ?? 0), titleSize: Double(font?.pointSize ?? 0),
                titleBold: font?.fontName == bold && bold != regular,
                titleOneLine: pill.titleField.maximumNumberOfLines == 1
                    && pill.titleField.lineBreakMode == .byTruncatingTail,
                titleX: Double(pill.titleField.frame.minX), iconX: Double(pill.iconView.frame.minX),
                iconSize: Double(pill.iconView.frame.width), hasFavicon: pill.iconView.contentTintColor == nil,
                shadowBlur: Double(shadow?.shadowBlurRadius ?? 0),
                shadowOffsetY: Double(shadow?.shadowOffset.height ?? 0),
                shadowOpacity: shadowOpacity, closeShown: !pill.closeButton.isHidden)
        }
        let zoom = controller.window?.standardWindowButton(.zoomButton)
        let buttons = zoom.map { Double($0.convert($0.bounds, to: content).maxX) } ?? 0
        return E2ETabStripState(
            pills: pills, plus: frame(of: feature.tabs.plusButton),
            plusTint: Self.stripHex(feature.tabs.plusButton.contentTintColor, in: appearance),
            buttonsTrailingEdge: buttons, stripWidth: Double(feature.tabs.bounds.width),
            viewportWidth: Double(feature.tabs.viewportWidth), scrollOffset: Double(feature.tabs.scrollOffset))
    }

    func pressTopPill(_ index: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "press a tab pill")
        try pill(index, in: page).activate()
    }

    func hoverTopPill(_ index: Int, _ hovered: Bool, in page: any E2EPage) throws {
        try adapter.requireActive(token, "hover a tab pill")
        try pill(index, in: page).isHovered = hovered
    }

    func clickTopPillClose(_ index: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click a tab pill's close button")
        let target = try pill(index, in: page)
        guard !target.closeButton.isHidden else { throw E2EError("pill \(index) shows no close button") }
        target.closeButton.performClick(nil)
    }

    func clickTopPlus(in page: any E2EPage) throws {
        try adapter.requireActive(token, "click the tab strip's + button")
        let (_, feature, _) = try stripParts(of: page)
        guard !feature.tabs.isHiddenOrHasHiddenAncestor else { throw E2EError("the tab strip is hidden") }
        feature.tabs.plusButton.performClick(nil)
    }

    private static func stripHex(_ color: NSColor?, in appearance: NSAppearance) -> String? {
        guard let color else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let rgb = resolved else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }

    private func pill(_ index: Int, in page: any E2EPage) throws -> TabPillView {
        let (_, feature, _) = try stripParts(of: page)
        guard feature.tabs.pills.indices.contains(index), !feature.tabs.isHiddenOrHasHiddenAncestor else {
            throw E2EError("the strip has no visible pill \(index) (\(feature.tabs.pills.count) pills)")
        }
        return feature.tabs.pills[index]
    }

    private func stripParts(of page: any E2EPage) throws -> (BrowserWindowController, TopTabsLayoutFeature, NSView) {
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let content = controller.window?.contentView, let feature = controller.feature(TopTabsLayoutFeature.self)
        else { throw E2EError("the window has no top tabs feature") }
        return (controller, feature, content)
    }
}
