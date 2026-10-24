import AppKit
import BowCore

/// Page zoom: View > Zoom In (Cmd+plus, and Cmd+= on a US keyboard), Zoom Out (Cmd+minus) and Actual Size (Cmd+0)
/// change the shown page's zoom by the preset sizes of `PageZoom`. The engine keeps zoom per site in the profile, so
/// every tab on the same site follows, now and later, and another site keeps its own.
///
/// The keys are claimed before the page (`KeyShortcuts`), so a page that handles them itself never sees them; the
/// menu items reach the same code through the responder chain and validate with the shown tab.
@MainActor
final class ZoomFeature: NSResponder, BrowserWindowFeature, NSMenuItemValidation {
    private unowned let window: BrowserWindowController

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    static func addMenuItems(to menus: MainMenu.Menus) {
        if !menus.view.items.isEmpty { menus.view.addItem(.separator()) }
        menus.view.addItem(withTitle: "Actual Size", action: #selector(actualSize(_:)), keyEquivalent: "0")
        // Cmd+= rather than "+", which AppKit reads as Cmd+Shift+=: that is Arc's Add Split View.
        menus.view.addItem(withTitle: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        menus.view.addItem(withTitle: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
    }

    @objc func zoomIn(_ sender: Any?) { apply(.zoomIn) }
    @objc func zoomOut(_ sender: Any?) { apply(.zoomOut) }
    @objc func actualSize(_ sender: Any?) { apply(.actualSize) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tab = zoomableTab else { return false }
        switch menuItem.action {
        case #selector(zoomIn(_:)): return PageZoom.zoomedIn(from: tab.zoomFactor) != nil
        case #selector(zoomOut(_:)): return PageZoom.zoomedOut(from: tab.zoomFactor) != nil
        case #selector(actualSize(_:)): return !PageZoom.isActualSize(tab.zoomFactor)
        default: return true
        }
    }

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard let shortcut = KeyShortcuts.shortcut(for: event, claimedBy: .zoom) else { return false }
        // The key is ours even at the largest or smallest size, so the page never sees it.
        if tab === window.selectedTab { apply(shortcut) }
        return true
    }

    private var zoomableTab: (any EngineTab)? {
        guard let tab = window.selectedTab, !tab.isClosed, !window.isClosing else { return nil }
        return tab
    }

    private func apply(_ shortcut: KeyShortcut) {
        guard let tab = zoomableTab else { return }
        let factor = tab.zoomFactor
        let next: Double? =
            switch shortcut {
            case .zoomIn: PageZoom.zoomedIn(from: factor)
            case .zoomOut: PageZoom.zoomedOut(from: factor)
            case .actualSize: PageZoom.actualSize
            default: nil
            }
        if let next { tab.setZoomFactor(next) }
    }
}
