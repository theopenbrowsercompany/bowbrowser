import AppKit
import BowCore

/// The archive button in the sidebar's footer, right of the downloads button: a Soft archive box that opens a popover
/// listing the profile's archived tabs and its "Archive tabs after" menu (`ArchivePopoverController`). Clicking it
/// again, clicking elsewhere or reopening an item closes the popover.
@MainActor
final class ArchiveFooterButton: SidebarAccessory {
    static var placement: SidebarAccessoryPlacement { .footer }

    static let symbolSize: CGFloat = 17
    static let identifier = "archive"

    let view: NSView
    private let button = ArchiveButton()

    init() {
        let stack = NSStackView(views: [button])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        view = stack
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = BowBrand.soft
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.symbolSize, weight: .regular)
        button.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archived Tabs")
        button.toolTip = "Archived Tabs"
        button.setAccessibilityLabel("Archived Tabs")
        button.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        button.target = self
        button.action = #selector(clicked(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func update(content: SidebarContent, context: (any SidebarActionContext)?) {}

    @objc private func clicked(_ sender: Any?) {
        if let popover = button.popover, popover.isShown {
            popover.close()
            return
        }
        guard let controller = button.window?.windowController as? BrowserWindowController else { return }
        let center = controller.appFeatures.require(ArchiveCenter.self)
        let content = ArchivePopoverController(center: center, window: controller)
        let popover = NSPopover()
        popover.behavior = .transient
        // Closing at once (not after a fade) keeps a second click on the button, or a reopened tab, from meeting a popover that is half gone.
        popover.animates = false
        popover.contentViewController = content
        content.close = { [weak popover] in popover?.close() }
        button.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
}

/// The button, holding the popover it opened (so the e2e harness can read what it shows).
@MainActor
final class ArchiveButton: NSButton {
    var popover: NSPopover?
}
