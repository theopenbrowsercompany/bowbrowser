import AppKit
import BowCore

// The start screen area of the adapter: E2EStartScreenApp over the empty state's StartScreenView.

extension E2ETestApp: E2EStartScreenApp {
    func startScreen(of page: any E2EPage) throws -> E2EStartScreenLook {
        try adapter.requireActive(token, "read the start screen")
        return try E2EAppAdapter.startScreen(of: E2EAppAdapter.tabPage(page).controller)
    }

    func clickStartSearch(in page: any E2EPage) throws {
        try adapter.requireActive(token, "click the start screen's search pill")
        let screen = try E2EAppAdapter.tabPage(page).controller.e2eEmptySpace.startScreen
        try E2EAppAdapter.performStartClick(screen.searchPill)
    }

    func clickQuickLink(_ index: Int, in page: any E2EPage) throws {
        try adapter.requireActive(token, "click a quick link")
        let screen = try E2EAppAdapter.tabPage(page).controller.e2eEmptySpace.startScreen
        guard screen.links.indices.contains(index) else {
            throw E2EError("the start screen has no quick link \(index) (it has \(screen.links.count))")
        }
        try E2EAppAdapter.performStartClick(screen.links[index])
    }

    func addFavorite(title: String, url: URL, in page: any E2EPage) throws -> String {
        try adapter.requireActive(token, "add a Favorite")
        var added: SidebarItemID?
        try adapter.changeSidebar(of: page) { added = try $0.addFavorite(url: url.absoluteString, title: title) }
        guard let added else { throw E2EError("no Favorite was added") }
        return added.rawValue
    }

    func deleteFavorite(_ item: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "delete a Favorite")
        try adapter.changeSidebar(of: page) { try $0.apply([.delete(SidebarItemID(item))]) }
    }

    func renameActiveSpace(_ title: String, in page: any E2EPage) throws {
        try adapter.requireActive(token, "rename the Space")
        try adapter.changeSidebar(of: page) { store in
            guard let space = store.graph.activeSpaceID else { throw E2EError("no Space is on screen") }
            try store.renameSpace(space, to: title)
        }
    }
}

extension E2EAppAdapter {
    /// An AppKit click on `button` (its cell's performClick), refused when it is not on screen.
    static func performStartClick(_ button: NSButton) throws {
        guard button.window != nil, !button.isHiddenOrHasHiddenAncestor, button.isEnabled else {
            throw E2EError("\"\(button.accessibilityLabel() ?? "the button")\" is not on screen")
        }
        button.performClick(nil)
    }

    static func startScreen(of controller: BrowserWindowController) throws -> E2EStartScreenLook {
        guard let content = controller.window?.contentView else { throw E2EError("the window has closed") }
        content.layoutSubtreeIfNeeded()
        let screen = controller.e2eEmptySpace.startScreen
        let shown = screen.window != nil && !screen.isHiddenOrHasHiddenAncestor
        let appearance = screen.effectiveAppearance
        func info(_ font: NSFont?) -> E2EFontInfo? {
            font.map { E2EFontInfo(family: $0.familyName ?? "", name: $0.fontName, size: Double($0.pointSize)) }
        }
        func hex(_ color: NSColor?) -> String? {
            guard let color else { return nil }
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            guard let rgb = resolved else { return nil }
            let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
            return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
        }
        func cgHex(_ color: CGColor?) -> String? { color.flatMap { NSColor(cgColor: $0) }.flatMap { hex($0) } }
        func frame(_ view: NSView) -> CGRect { screen.convert(view.bounds, from: view) }
        let visibleLinks = screen.links.filter { $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor }
        let parts: [NSView] = [
            screen.markView, screen.greetingLabel, screen.searchPill, screen.linksRow, screen.hintLabel,
        ]
        .filter { $0.superview != nil && !$0.isHiddenOrHasHiddenAncestor }
        let frames = parts.map(frame)
        let gaps = zip(frames, frames.dropFirst()).map { Double($0.minY - $1.maxY) }
        let first = visibleLinks.first
        let pillLayer = screen.searchPill.layer
        return E2EStartScreenLook(
            isShown: shown,
            greeting: screen.greetingLabel.stringValue,
            greetingHour: screen.greetingHour,
            greetingFont: info(screen.greetingLabel.font),
            greetingColor: hex(screen.greetingLabel.textColor),
            markSize: screen.markView.image == nil ? .zero : screen.markView.frame.size,
            hint: screen.hintLabel.stringValue,
            hintFont: info(screen.hintLabel.font),
            hintColor: hex(screen.hintLabel.textColor),
            pillFrame: frame(screen.searchPill),
            pillRadius: Double(pillLayer?.cornerRadius ?? 0),
            pillFill: cgHex(pillLayer?.backgroundColor),
            pillBorder: cgHex(pillLayer?.borderColor),
            pillBorderWidth: Double(pillLayer?.borderWidth ?? 0),
            placeholder: screen.searchPill.placeholderLabel.stringValue,
            placeholderFont: info(screen.searchPill.placeholderLabel.font),
            linkTitles: visibleLinks.map(\.titleLabel.stringValue),
            linkIcons: visibleLinks.map { $0.iconView.image != nil && !$0.iconView.isHidden },
            linkFrame: first.map(frame) ?? .zero,
            tileSize: first?.tile.frame.size ?? .zero,
            tileRadius: Double(first?.tile.layer?.cornerRadius ?? 0),
            tileFill: cgHex(first?.tile.layer?.backgroundColor),
            linkTitleFont: info(first?.titleLabel.font),
            gaps: gaps,
            bounds: screen.bounds,
            contentFrame: frames.reduce(CGRect.null) { $0.union($1) },
            drawsDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}
