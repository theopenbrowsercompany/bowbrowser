import AppKit

// The fonts area of the adapter: E2EFontsApp over the font tokens and the text surfaces of a window.

extension E2ETestApp: E2EFontsApp {
    func fonts(of page: any E2EPage) throws -> E2EFontsLook {
        try adapter.requireActive(token, "read the fonts")
        let controller = try E2EAppAdapter.tabPage(page).controller
        func info(_ font: NSFont?) -> E2EFontInfo? {
            font.map { E2EFontInfo(family: $0.familyName ?? "", name: $0.fontName, size: Double($0.pointSize)) }
        }
        let families = NSFontManager.shared.availableFontFamilies
        let resources = Bundle.main.resourceURL
        func size(_ path: String) -> Int {
            resources.flatMap { try? Data(contentsOf: $0.appendingPathComponent(path)).count } ?? 0
        }
        let sidebar = controller.e2eSidebar
        let row = controller.tabList.activeID
            .flatMap { controller.sidebarItemID(for: $0) }
            .flatMap { sidebar.rowView(for: $0) }
        let spaceName = E2EAppAdapter.views(in: sidebar.outlineView, NSTextField.self).first {
            $0.identifier?.rawValue == "space-name"
        }
        let spaceFont =
            spaceName?.attributedStringValue.attribute(
                .font, at: 0, effectiveRange: nil) as? NSFont
        let empty = controller.e2eEmptySpace
        return E2EFontsLook(
            nunitoRegistered: families.contains(BowBrand.uiFamily),
            fredokaRegistered: families.contains(BowBrand.displayFamily),
            jetBrainsPresent: families.contains { $0.hasPrefix("JetBrains") }
                || size("Fonts/JetBrainsMono.ttf") > 0,
            fontFilesBundled: size("Fonts/NunitoSans.ttf") > 0 && size("Fonts/Fredoka.ttf") > 0,
            licenseFilesBundled: size("OFL-NunitoSans.txt") > 0 && size("OFL-Fredoka.txt") > 0,
            uiToken: info(BowBrand.ui())!,
            displayToken: info(BowBrand.display())!,
            activeRow: info(row?.titleField.font),
            spaceName: info(spaceFont),
            commandBarField: info(controller.feature(CommandBarFeature.self)?.panel.field.font),
            emptyStateLine: empty.window == nil ? nil : info(empty.messageLabel.font))
    }
}
