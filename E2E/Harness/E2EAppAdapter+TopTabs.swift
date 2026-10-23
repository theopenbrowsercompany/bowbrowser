import AppKit
import BowCore

// The top tabs area of the adapter: E2ETopTabsApp over the window's TopTabsLayoutFeature, its sidebar and page card,
// and the View menu item that switches the layout.

extension E2ETestApp: E2ETopTabsApp {
    func topTabs(of page: any E2EPage) throws -> E2ETopTabsState {
        try adapter.requireActive(token, "read the top tabs layout")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let window = controller.window, let content = window.contentView,
            let feature = controller.feature(TopTabsLayoutFeature.self)
        else { throw E2EError("the window has no top tabs feature") }
        content.layoutSubtreeIfNeeded()
        let sidebar = controller.e2eSidebar
        // Frames from the window's top and leading edges.
        func frame(of view: NSView) -> E2ETopFrame {
            let rect = view.convert(view.bounds, to: content)
            return E2ETopFrame(
                x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        let navigation = controller.e2eNavigationToolbar
        var items: [String: E2ETopFrame] = [:]
        var order: [String] = []
        for item in NavigationToolbar.Item.allCases {
            items[item.rawValue] = frame(of: navigation.button(item))
            order.append(item.rawValue)
        }
        items["url"] = frame(of: feature.urlField)
        items["dots"] = frame(of: feature.spaces.view)
        order += ["url", "dots"]
        let dots = Self.dotButtons(in: feature)
        let active = dots.first { $0.accessibilityValue() as? String == "on screen" }
        let appearance = window.effectiveAppearance
        let item = NSApp.mainMenu?.items.lazy.compactMap { $0.submenu }.flatMap(\.items).first {
            $0.action == #selector(TopTabsLayoutFeature.toggleTopTabs(_:))
        }
        if let item { _ = feature.validateMenuItem(item) }
        let pageFrame = controller.pageArea.convert(controller.pageArea.bounds, to: content)
        let closeFrame = window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: content) }
        let first = items[order[0]] ?? E2ETopFrame(x: 0, y: 0, width: 0, height: 0)
        let last = items["dots"] ?? first
        return E2ETopTabsState(
            saved: AppSettings.defaults.string(forKey: AppSettings.windowLayoutKey),
            menuTitle: item?.title ?? "none", menuChecked: item?.state == .on,
            sidebarHidden: sidebar.isHiddenOrHasHiddenAncestor,
            sidebarMinX: Double(sidebar.convert(sidebar.bounds, to: content).minX),
            barShown: !feature.strip.isHiddenOrHasHiddenAncestor,
            stripHeight: Double(feature.strip.bounds.height), toolbarHeight: Double(feature.toolbarRow.bounds.height),
            items: items, itemOrder: order, leadingPadding: first.x,
            trailingPadding: Double(content.bounds.width) - last.maxX,
            navigationTint: Self.hex(navigation.backButton.contentTintColor, in: appearance),
            urlText: feature.urlField.text, urlRadius: Double(feature.urlField.layer?.cornerRadius ?? 0),
            urlFill: Self.hex(
                feature.urlField.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }, in: appearance),
            dotCount: dots.count, activeDotRing: Double(active?.layer?.borderWidth ?? 0),
            dotSize: Double(active?.image?.size.width ?? 0), activeDotName: active?.accessibilityLabel(),
            pageInsets: [
                Double(content.bounds.height - pageFrame.maxY), Double(pageFrame.minX), Double(pageFrame.minY),
                Double(content.bounds.width - pageFrame.maxX),
            ],
            pageRadius: Double(controller.pageArea.layer?.cornerRadius ?? 0),
            closeButtonX: Double(closeFrame?.minX ?? 0),
            closeButtonMidY: Double(closeFrame.map { content.bounds.height - $0.midY } ?? 0))
    }

    func chooseUseTopTabs(in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose View > Use Top Tabs")
        try adapter.chooseMenuItem(path: ["View", WindowLayout.menuTitle], in: page)
    }

    func clickTopSpaceDot(_ index: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click a Space dot")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(TopTabsLayoutFeature.self) else {
            throw E2EError("the window has no top tabs feature")
        }
        let dots = Self.dotButtons(in: feature)
        guard dots.indices.contains(index), !dots[index].isHiddenOrHasHiddenAncestor else {
            throw E2EError("the toolbar row has no visible Space dot \(index) (\(dots.count) dots)")
        }
        dots[index].performClick(nil)
    }

    private static func dotButtons(in feature: TopTabsLayoutFeature) -> [NSButton] {
        E2EAppAdapter.views(in: feature.toolbarRow, NSButton.self).filter {
            $0.identifier?.rawValue == "space-icon"
        }
    }

    private static func hex(_ color: NSColor?, in appearance: NSAppearance) -> String? {
        guard let color else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let rgb = resolved else { return nil }
        let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
    }
}
