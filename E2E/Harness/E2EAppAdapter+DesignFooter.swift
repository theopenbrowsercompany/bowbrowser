import AppKit
import BowCore

// The design area's footer surface: the Space dots, their colors and menu, and the buttons around them.

extension E2EAppAdapter {
    static func footerLook(of controller: BrowserWindowController) -> E2EDesignFooterLook {
        let sidebar = controller.e2eSidebar
        let appearance = controller.window?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let dot = views(in: sidebar.footer, NSButton.self).first {
            $0.identifier?.rawValue == "space-icon" && $0.accessibilityValue() as? String == "on screen"
        }
        sidebar.footer.layoutSubtreeIfNeeded()
        let footerButtons = views(in: sidebar.footer, NSButton.self)
        let dots = footerButtons.filter { $0.identifier?.rawValue == "space-icon" }
        func footerButton(_ id: String) -> NSButton? { footerButtons.first { $0.identifier?.rawValue == id } }
        func inFooter(_ view: NSView) -> CGRect { sidebar.footer.convert(view.bounds, from: view) }
        var offset = 0.0
        var order = false
        if let downloads = footerButton("downloads"), let archive = footerButton("archive"),
            let plus = footerButton("new-space"), let first = dots.first, let last = dots.last
        {
            let gapMid = (inFooter(archive).maxX + inFooter(plus).minX) / 2
            offset = Double((inFooter(first).minX + inFooter(last).maxX) / 2 - gapMid)
            order =
                inFooter(downloads).maxX <= inFooter(archive).minX && inFooter(archive).maxX <= inFooter(first).minX
                && inFooter(last).maxX <= inFooter(plus).minX
        }
        var menuTitles: [String] = []
        if let dot, let window = dot.window,
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: dot.convert(NSPoint(x: 4, y: 4), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1),
            let menu = dot.menu(for: event)
        {
            menuTitles = menu.items.flatMap { item -> [String] in
                guard !item.isSeparatorItem else { return ["-"] }
                return [item.title] + (item.submenu?.items.map { "\(item.title)/\($0.title)" } ?? [])
            }
        }
        let dotSize = Double(dot?.image?.size.width ?? 0)
        let ringWidth = Double(dot?.layer?.borderWidth ?? 0)
        return E2EDesignFooterLook(
            spaceDotSize: dotSize,
            spaceRingWidth: ringWidth,
            spaceRingGap: dot.map { (Double($0.bounds.width) - dotSize) / 2 - ringWidth } ?? 0,
            spaceRingColor: dot?.layer?.borderColor.flatMap { NSColor(cgColor: $0) }.flatMap {
                designHex($0, in: appearance)
            },
            dotsOffset: offset,
            order: order,
            dotColors: dots.map { designHex($0.contentTintColor, in: appearance) },
            dotMenu: menuTitles)
    }
}
