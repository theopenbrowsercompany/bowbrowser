import AppKit
import BowCore

/// A small Soft arrow button at the end of a pinned tab's row, shown only while its page has navigated away from the
/// saved address; it loads the saved address again ("Back to Pinned URL"). Nothing else changes: the saved address
/// stays as it was.
enum BackToPinnedAccessory: SidebarRowAccessory {
    static let identifier = NSUserInterfaceItemIdentifier("backToPinned")

    static func accessoryView(
        for item: SidebarItemID, reusing view: NSView?, content: SidebarContent,
        context: (any SidebarActionContext)?
    ) -> NSView? {
        guard let context, let live = context.livePage(of: item),
            context.graph.hasNavigatedAwayFromPinnedURL(item, liveURL: live.url)
        else { return nil }
        let button = (view as? BackToPinnedButton) ?? BackToPinnedButton()
        button.item = item
        button.context = context
        return button
    }
}

@MainActor
final class BackToPinnedButton: NSButton {
    var item: SidebarItemID?
    weak var context: (any SidebarActionContext)?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Back to Pinned URL")
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = BowBrand.soft
        toolTip = "Back to Pinned URL"
        setAccessibilityLabel("Back to Pinned URL")
        identifier = BackToPinnedAccessory.identifier
        target = self
        action = #selector(goBack(_:))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func goBack(_ sender: Any?) {
        guard let item, let context, let url = context.graph.pinnedURL(of: item) else { return }
        context.load(item, url: url)
    }
}
