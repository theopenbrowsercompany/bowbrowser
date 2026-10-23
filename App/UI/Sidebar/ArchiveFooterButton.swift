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
        if button.popover?.isShown == true {
            button.closePopover()
            return
        }
        // A real click on the button while the popover shows first closes it (a transient popover closes on any click
        // outside it), so the click that follows must not open it again.
        if button.closedByOutsideClickJustNow { return }
        guard let controller = button.window?.windowController as? BrowserWindowController else { return }
        let center = controller.appFeatures.require(ArchiveCenter.self)
        let content = ArchivePopoverController(center: center, window: controller)
        let popover = NSPopover()
        popover.behavior = .transient
        // Closing at once (not after a fade) keeps a second click on the button, or a reopened tab, from meeting a popover that is half gone.
        popover.animates = false
        popover.contentViewController = content
        content.close = { [weak button] in button?.closePopover() }
        popover.delegate = button
        button.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
}

/// The button, holding the popover it opened (so the e2e harness can read what it shows).
@MainActor
final class ArchiveButton: NSButton, NSPopoverDelegate {
    var popover: NSPopover?
    private var closingOnPurpose = false
    private var outsideClose: Date?

    /// Closes the popover for the button or a reopened tab (not because of a click outside it).
    func closePopover() {
        closingOnPurpose = true
        popover?.close()
        closingOnPurpose = false
    }

    /// True within a moment of AppKit closing the popover for a click outside it.
    var closedByOutsideClickJustNow: Bool {
        guard let outsideClose else { return false }
        return Date().timeIntervalSince(outsideClose) < 0.25
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClose = closingOnPurpose ? nil : Date()
        popover = nil
    }
}
