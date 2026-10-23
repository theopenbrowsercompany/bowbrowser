import AppKit
import BowCore

/// The New Tab row that ends a Space's tab list, after today's tabs. It is a section without a container: its header
/// row is the whole row, so it is never selected, dragged, dropped onto or counted as a tab. Clicking it opens the
/// command bar for a new tab, as Cmd+T does (Arc's sidebar button opens the command bar too; the mockup puts it at
/// the end of the list).
struct NewTabSection: SidebarSection {
    var zone: SidebarZone? { nil }
    var headerHeight: CGFloat { NewTabRowView.height }

    func containerID(in graph: SidebarGraph, space: SidebarSpace) -> SidebarItemID? { nil }

    func makeHeaderView() -> NSView? { NewTabRowView() }

    func updateHeaderView(_ view: NSView, content: SidebarContent, context: (any SidebarActionContext)?) {
        (view as? NewTabRowView)?.context = context
    }
}

/// The New Tab row drawn like a tab row: 34 high, a plus symbol and "New tab" in Soft, a Pin tint on hover.
@MainActor
final class NewTabRowView: NSView {
    static let height: CGFloat = 34
    static let title = "New tab"

    weak var context: (any SidebarActionContext)?
    let titleField = NSTextField(labelWithString: NewTabRowView.title)
    let iconView = NSImageView()
    /// The rounded rect behind the row's content, inside the sidebar's padding.
    private let lift = SidebarRowLift()
    private var isHovered = false {
        didSet { updateLift() }
    }

    init() {
        super.init(frame: .zero)
        let symbol = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbol)
        iconView.contentTintColor = BowBrand.soft
        titleField.font = BowBrand.ui()
        titleField.textColor = BowBrand.soft
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true

        for view in [lift, iconView, titleField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            lift.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BowBrand.sidebarLeading),
            lift.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BowBrand.sidebarTrailing),
            lift.topAnchor.constraint(equalTo: topAnchor),
            lift.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: lift.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: lift.trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.title)
        updateLift()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// What a click does: opens the command bar for a new tab. False while the row has no window to act on.
    @discardableResult
    func activate() -> Bool {
        guard let context else { return false }
        context.openNewTab()
        return true
    }

    override func accessibilityPerformPress() -> Bool { activate() }

    /// The row takes its own clicks, which the outline would otherwise read as a press on a section header.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Shows or clears the hover tint, as the pointer entering or leaving the row does.
    func setHovered(_ hovered: Bool) { isHovered = hovered }

    /// The color behind the row now, nil without a tint.
    var backgroundColor: CGColor? { lift.layer?.backgroundColor }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLift()
    }

    private func updateLift() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            lift.layer?.backgroundColor = isHovered ? BowBrand.pin.cgColor : nil
        }
    }
}
