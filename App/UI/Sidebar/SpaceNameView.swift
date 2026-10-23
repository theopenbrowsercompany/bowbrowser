import AppKit
import BowCore

/// The name of the Space on screen, as the pinned section's header: below the Favorites grid and above the Space's
/// tabs, where Arc puts it. Double-clicking it renames the Space, and its context menu renames or deletes it, followed
/// by the pinned section's own items (New Folder), which its row showed before it had a name on it.
@MainActor
final class SpaceNameView: NSView {
    /// The header row's height: the 11 point label with 4 points above and below.
    static let height: CGFloat = 22

    let label = NSTextField(labelWithString: "")
    private weak var context: (any SidebarActionContext)?
    private var spaceID: SidebarSpaceID?
    private var pinnedContainerID: SidebarItemID?

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.identifier = NSUserInterfaceItemIdentifier("space-name")
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // A group label: inset 10 within the sidebar's own padding.
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BowBrand.sidebarLeading + 10),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -(BowBrand.sidebarTrailing + 10)),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(content: SidebarContent, context: (any SidebarActionContext)?) {
        self.context = context
        let space = content.graph.activeSpace
        spaceID = space?.id
        pinnedContainerID = space?.pinnedContainerID
        let title = space.map(Self.title(of:)) ?? ""
        // Shown as an 11 point bold uppercase label in Soft; the tooltip keeps the name as typed.
        label.attributedStringValue = NSAttributedString(
            string: title.localizedUppercase,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold), .kern: 0.8, .foregroundColor: BowBrand.soft,
            ])
        label.toolTip = title
        label.setAccessibilityLabel(space.map { "Space \($0.title)" })
    }

    static func title(of space: SidebarSpace) -> String {
        if let icon = space.icon, icon.kind == .emoji { return "\(icon.value) \(space.title)" }
        return space.title
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let context, let spaceID {
            SpaceActions.rename(spaceID, context: context, window: window)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let context, let spaceID else { return super.menu(for: event) }
        var items = SpaceActions.menuItems(for: spaceID, context: context) { [weak self] in self?.window }
        if let pinnedContainerID {
            let section = SidebarMenus.menu(for: pinnedContainerID, kind: .section(.pinned), context: context)
            if !section.isEmpty { items += [.separator()] + section }
        }
        return SpaceActions.contextMenu(items)
    }
}
