import AppKit
import BowCore

/// The downloads button at the left of the sidebar's footer: a Soft downloads symbol that opens the downloads window
/// (the same window Window > Downloads shows, brought forward when already open). While a download runs the symbol
/// is the filled one, following the app's downloads list.
@MainActor
final class DownloadsFooterButton: SidebarAccessory {
    static var placement: SidebarAccessoryPlacement { .footer }

    static let symbolSize: CGFloat = 17
    static let identifier = "downloads"

    let view: NSView
    private let button = DownloadsButton()
    private var isActive = false

    init() {
        let stack = NSStackView(views: [button])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        view = stack
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = BowBrand.soft
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.symbolSize, weight: .regular)
        button.toolTip = "Downloads"
        button.setAccessibilityLabel("Downloads")
        button.identifier = NSUserInterfaceItemIdentifier(Self.identifier)
        button.target = self
        button.action = #selector(clicked(_:))
        button.movedToWindow = { [weak self] in self?.refresh(from: self?.center) }
        show(active: false, force: true)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(listChanged(_:)), name: DownloadsCenter.listDidChange, object: nil)
    }

    func update(content: SidebarContent, context: (any SidebarActionContext)?) {
        refresh(from: center)
    }

    /// The app's downloads center, reached through the window the button is in.
    private var center: DownloadsCenter? {
        (button.window?.windowController as? BrowserWindowController)?.appFeatures.require(DownloadsCenter.self)
    }

    private func refresh(from center: DownloadsCenter?) {
        guard let center else { return }
        show(active: center.list.activeCount > 0)
    }

    private func show(active: Bool, force: Bool = false) {
        guard force || active != isActive else { return }
        isActive = active
        let name = active ? "arrow.down.circle.fill" : "arrow.down.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Downloads")
        button.setAccessibilityValue(active ? "Download in progress" : nil)
    }

    @objc private func listChanged(_ note: Notification) {
        refresh(from: note.object as? DownloadsCenter)
    }

    @objc private func clicked(_ sender: Any?) {
        guard let controller = center?.openWindow() else { return }
        // A minimized downloads window comes back out of the Dock too.
        if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(sender) }
        controller.showWindow(sender)
    }
}

/// The button, telling the accessory when it joins a window so it can show that window's downloads at once.
@MainActor
private final class DownloadsButton: NSButton {
    var movedToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { movedToWindow?() }
    }
}
