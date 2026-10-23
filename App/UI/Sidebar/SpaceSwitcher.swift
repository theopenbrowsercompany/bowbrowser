import AppKit
import BowCore

/// What a person can do to Spaces from the sidebar and the menu bar: show one (with the outline sliding towards it),
/// create, rename and delete. Everything goes through the window's `SidebarActionContext`, so the store rules
/// (the last Space stays, a deleted Space's neighbour comes on screen) and the window's update follow from the store.
@MainActor
enum SpaceActions {
    /// Shows Space `id` with the outline sliding towards it: the old content leaves to the left when `id` comes after
    /// the Space on screen and to the right when it comes before. Showing the Space already on screen does nothing.
    static func show(_ id: SidebarSpaceID, context: any SidebarActionContext) {
        let graph = context.graph
        guard let current = graph.activeSpaceID, current != id,
            let from = graph.spaces.firstIndex(where: { $0.id == current }),
            let to = graph.spaces.firstIndex(where: { $0.id == id })
        else { return }
        context.slideOutline(to > from ? .left : .right) {
            context.changeSidebar { try $0.switchToSpace(id) }
        }
    }

    /// Shows the Space before or after the one on screen. Returns false at the first or last Space, where nothing
    /// changes: switching does not wrap around.
    @discardableResult
    static func showAdjacent(_ direction: SpaceDirection, context: any SidebarActionContext) -> Bool {
        guard let id = context.graph.adjacentSpaceID(direction) else { return false }
        show(id, context: context)
        return true
    }

    /// Shows the `number`th Space (1 is the first), as Ctrl+1 to Ctrl+9 do. A number with no Space does nothing.
    static func show(number: Int, context: any SidebarActionContext) {
        guard let id = context.graph.spaceID(shortcutNumber: number) else { return }
        show(id, context: context)
    }

    /// Adds an empty Space at the end of the list, named "Space N" (`SidebarGraph.newSpaceTitle`), and shows it,
    /// sliding in from the right.
    static func create(context: any SidebarActionContext) {
        let title = context.graph.newSpaceTitle
        context.slideOutline(.left) {
            context.changeSidebar { try $0.createSpace(title: title) }
        }
    }

    /// Whether Space `id` may be deleted: it exists and is not the window's last Space.
    static func canDelete(_ id: SidebarSpaceID, in graph: SidebarGraph) -> Bool {
        graph.space(id) != nil && graph.spaces.count > 1
    }

    /// Asks for a new name for Space `id` in a sheet on `window` (a dialog without one), showing its name selected.
    /// Rename saves the trimmed name; an empty name, or Cancel, keeps the old one.
    static func rename(_ id: SidebarSpaceID, context: any SidebarActionContext, window: NSWindow?) {
        guard let space = context.graph.space(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        alert.informativeText = "Enter a new name for “\(space.title)”."
        let field = NSTextField(string: space.title)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.setAccessibilityLabel("Space name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, on: window) { [weak context] response in
            guard response == .alertFirstButtonReturn, let context, let current = context.graph.space(id) else {
                return
            }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != current.title else { return }
            context.changeSidebar { try $0.renameSpace(id, to: title) }
        }
    }

    /// Deletes Space `id` with its pinned tabs and tabs. A Space with tabs asks first in a sheet on `window`; an empty
    /// one goes at once. The last Space is never deleted. If it was on screen, its neighbour slides in.
    static func delete(_ id: SidebarSpaceID, context: any SidebarActionContext, window: NSWindow?) {
        let graph = context.graph
        guard canDelete(id, in: graph), let space = graph.space(id) else { return }
        let tabCount = graph.tabIDs(in: id).count
        guard tabCount > 0 else {
            performDelete(id, context: context)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(space.title)”?"
        alert.informativeText =
            tabCount == 1
            ? "Its tab closes with it. This cannot be undone."
            : "Its \(tabCount) tabs close with it. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        present(alert, on: window) { [weak context] response in
            guard response == .alertFirstButtonReturn, let context else { return }
            performDelete(id, context: context)
        }
    }

    private static func performDelete(_ id: SidebarSpaceID, context: any SidebarActionContext) {
        let graph = context.graph
        guard canDelete(id, in: graph) else { return }
        let change = { _ = context.changeSidebar { try $0.deleteSpace(id) } }
        guard graph.activeSpaceID == id, let position = graph.spaces.firstIndex(where: { $0.id == id }) else {
            change()
            return
        }
        // The next Space takes its place, or the previous one when it was last.
        let neighbourIsNext = position + 1 < graph.spaces.count
        context.slideOutline(neighbourIsNext ? .left : .right, change: change)
    }

    private static func present(
        _ alert: NSAlert, on window: NSWindow?, then handler: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        guard let window else {
            handler(alert.runModal())
            return
        }
        // One question at a time: a second one while a sheet is up is dropped.
        guard window.attachedSheet == nil else { return }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { handler(response) }
        }
    }

    /// The Space actions as menu items for Space `id`, for its footer icon and the name header.
    static func menuItems(for id: SidebarSpaceID, context: any SidebarActionContext, window: @escaping () -> NSWindow?)
        -> [NSMenuItem]
    {
        let renameItem = SidebarMenuItem(title: "Rename Space…") { [weak context] in
            guard let context else { return }
            rename(id, context: context, window: window())
        }
        let deleteItem = SidebarMenuItem(title: "Delete Space…") { [weak context] in
            guard let context else { return }
            delete(id, context: context, window: window())
        }
        deleteItem.isEnabled = canDelete(id, in: context.graph)
        return [renameItem, deleteItem]
    }

    /// A context menu of `items` as given (each item keeps its own enabled state), nil for none.
    static func contextMenu(_ items: [NSMenuItem]) -> NSMenu? {
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }
}

/// The name of the Space on screen, at the top of the sidebar above its tabs. Double-clicking it renames the Space,
/// and its context menu renames or deletes it.
@MainActor
final class SpaceNameHeader: SidebarAccessory {
    static var placement: SidebarAccessoryPlacement { .top }

    let view: NSView
    private let label = NSTextField(labelWithString: "")
    private weak var context: (any SidebarActionContext)?
    private var spaceID: SidebarSpaceID?

    init() {
        let container = SpaceHeaderView()
        view = container
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = BowBrand.text
        label.lineBreakMode = .byTruncatingTail
        label.identifier = NSUserInterfaceItemIdentifier("space-name")
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: BowBrand.space16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -BowBrand.space8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: BowBrand.space4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -BowBrand.space4),
        ])
        container.onDoubleClick = { [weak self] in self?.renameShownSpace() }
        container.makeMenu = { [weak self] in self?.menuItems() ?? [] }
    }

    func update(content: SidebarContent, context: (any SidebarActionContext)?) {
        self.context = context
        let space = content.graph.activeSpace
        spaceID = space?.id
        label.stringValue = space.map(Self.title(of:)) ?? ""
        label.setAccessibilityLabel(space.map { "Space \($0.title)" })
    }

    static func title(of space: SidebarSpace) -> String {
        if let icon = space.icon, icon.kind == .emoji { return "\(icon.value) \(space.title)" }
        return space.title
    }

    private func renameShownSpace() {
        guard let context, let spaceID else { return }
        SpaceActions.rename(spaceID, context: context, window: view.window)
    }

    private func menuItems() -> [NSMenuItem] {
        guard let context, let spaceID else { return [] }
        return SpaceActions.menuItems(for: spaceID, context: context) { [weak view] in view?.window }
    }
}

/// The view behind the Space name header: a double-click and a context menu.
@MainActor
private final class SpaceHeaderView: NSView {
    var onDoubleClick: (() -> Void)?
    var makeMenu: (() -> [NSMenuItem])?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        SpaceActions.contextMenu(makeMenu?() ?? [])
    }
}

/// The Space switcher in the sidebar's footer: one icon per Space in order, the one on screen highlighted, and a "+"
/// that creates a Space. Clicking an icon shows its Space, and its context menu renames or deletes it. It also takes
/// the sidebar's sideways two-finger swipes, which move to the next or previous Space.
@MainActor
final class SpaceSwitcher: SidebarAccessory {
    static var placement: SidebarAccessoryPlacement { .footer }

    let view: NSView
    let swipeHandler: (any SidebarSwipeHandler)? = SpaceSwipeHandler()
    private let icons = NSStackView()
    let newSpaceButton: NSButton
    private weak var context: (any SidebarActionContext)?
    /// What the icons show now, so an update that changes nothing leaves them alone.
    private var shown: [Shown] = []

    private struct Shown: Equatable {
        var id: SidebarSpaceID
        var title: String
        var icon: SpaceIcon?
        var isActive: Bool
    }

    init() {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: BowBrand.space8, left: 0, bottom: BowBrand.space8, right: 0)
        view = stack
        icons.orientation = .horizontal
        icons.spacing = 2
        // Many Spaces narrow their icons, then clip at the footer's edge, rather than widening the sidebar.
        icons.setClippingResistancePriority(.defaultLow, for: .horizontal)
        icons.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newSpaceButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Space") ?? NSImage(),
            target: nil, action: nil)
        newSpaceButton.isBordered = false
        newSpaceButton.contentTintColor = BowBrand.secondaryText
        newSpaceButton.toolTip = "New Space"
        newSpaceButton.setAccessibilityLabel("New Space")
        newSpaceButton.identifier = NSUserInterfaceItemIdentifier("new-space")
        newSpaceButton.target = self
        newSpaceButton.action = #selector(newSpaceClicked(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(icons)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(newSpaceButton)
        NSLayoutConstraint.activate([
            newSpaceButton.widthAnchor.constraint(equalToConstant: 24),
            newSpaceButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func update(content: SidebarContent, context: (any SidebarActionContext)?) {
        self.context = context
        let graph = content.graph
        let next = graph.spaces.map {
            Shown(id: $0.id, title: $0.title, icon: $0.icon, isActive: $0.id == graph.activeSpaceID)
        }
        guard next != shown else { return }
        shown = next
        for view in icons.arrangedSubviews {
            icons.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for space in next { icons.addArrangedSubview(button(for: space)) }
    }

    private func button(for space: Shown) -> NSButton {
        let button = SpaceIconButton(title: "", target: self, action: #selector(iconClicked(_:)))
        button.spaceID = space.id
        button.isBordered = false
        button.toolTip = space.title
        button.identifier = NSUserInterfaceItemIdentifier("space-icon")
        button.setAccessibilityLabel(space.title)
        button.setAccessibilityValue(space.isActive ? "on screen" : nil)
        button.setButtonType(.momentaryChange)
        button.contentTintColor = space.isActive ? BowBrand.text : BowBrand.secondaryText
        switch space.icon?.kind {
        case .emoji?:
            button.title = space.icon?.value ?? ""
            button.font = .systemFont(ofSize: 13)
            button.alphaValue = space.isActive ? 1 : 0.55
        case .symbol?:
            button.image = space.icon.flatMap {
                NSImage(systemSymbolName: $0.value, accessibilityDescription: space.title)
            }
        case nil:
            // Arc's default: a dot, filled for the Space on screen.
            button.image = NSImage(
                systemSymbolName: space.isActive ? "circle.fill" : "circle", accessibilityDescription: space.title)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        }
        if button.image == nil, button.title.isEmpty { button.title = String(space.title.prefix(1)) }
        button.makeMenu = { [weak self] in
            guard let self, let context = self.context else { return [] }
            return SpaceActions.menuItems(for: space.id, context: context) { [weak self] in self?.view.window }
        }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22).withPriority(.defaultLow),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    @objc private func iconClicked(_ sender: SpaceIconButton) {
        guard let context, let id = sender.spaceID else { return }
        SpaceActions.show(id, context: context)
    }

    @objc private func newSpaceClicked(_ sender: Any?) {
        guard let context else { return }
        SpaceActions.create(context: context)
    }
}

/// A Space's icon in the switcher, with that Space's context menu.
@MainActor
private final class SpaceIconButton: NSButton {
    var spaceID: SidebarSpaceID?
    var makeMenu: (() -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        SpaceActions.contextMenu(makeMenu?() ?? [])
    }
}

/// Moves to the next or previous Space when a sideways two-finger swipe on the sidebar ends far enough. The swipe
/// moves the Spaces the way the person's scroll direction setting moves content sideways: with natural scrolling
/// (the default), fingers moving left bring in the next Space from the right and fingers moving right the previous
/// one, as pages turn. It stops at the first and last Space. It keeps no reference to the sidebar or its window: it acts on the context each swipe brings.
@MainActor
final class SpaceSwipeHandler: SidebarSwipeHandler {
    /// How far, in points, the swipe must move sideways before the fingers lift for it to switch Spaces.
    static let distance: CGFloat = 40

    func sidebarSwipe(_ swipe: SidebarSwipe, context: any SidebarActionContext) {
        guard swipe.phase == .ended, abs(swipe.translation) >= Self.distance else { return }
        SpaceActions.showAdjacent(swipe.translation < 0 ? .next : .previous, context: context)
    }
}

extension NSLayoutConstraint {
    fileprivate func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
