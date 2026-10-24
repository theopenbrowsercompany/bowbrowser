import AppKit
import BowCore

// The design area's command bar surface: the panel's clipped corners and its shadow path.

extension E2EAppAdapter {
    static func commandBarLook(of controller: BrowserWindowController) -> E2EDesignCommandBarLook {
        let panel = controller.feature(CommandBarFeature.self)?.panel
        let content = panel?.content.layer
        return E2EDesignCommandBarLook(
            radius: Double(content?.cornerRadius ?? 0),
            clips: content?.masksToBounds ?? false,
            shadowHasPath: panel.map { panel in
                panel.bounds.width > 0
                    && panel.layer?.shadowPath.map { $0.boundingBox.size == panel.bounds.size } ?? false
            } ?? false)
    }
}
