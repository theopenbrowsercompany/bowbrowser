import AppKit

/// The row view behind each sidebar item: the active tab's row is a lifted Card colored rounded rect with a very light
/// shadow, a hovered row gets a light Hover tint, and every other row has no background. The outline's own selection
/// highlight is not drawn, and the row is never emphasized, so titles keep their own color when selected.
@MainActor
final class SidebarRowView: NSTableRowView {
    /// Space between the lifted rect and the sidebar's edges.
    static let horizontalInset = BowBrand.space8
    static let shadowOpacity: Float = 0.08
    static let shadowRadius: CGFloat = 2
    static let shadowOffset = CGSize(width: 0, height: -1)

    /// The rounded rect behind the row's cell, below it.
    let liftView = SidebarRowLift()
    private var isHovered = false {
        didSet { updateLift() }
    }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(liftView, positioned: .below, relativeTo: nil)
        updateLift()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isSelected: Bool {
        didSet { updateLift() }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    /// The lift view stands for the selection, so the outline's highlight is not drawn.
    override func drawSelection(in dirtyRect: NSRect) {}

    override func layout() {
        super.layout()
        liftView.frame = bounds.insetBy(dx: Self.horizontalInset, dy: 0)
        liftView.layer?.shadowPath = CGPath(
            roundedRect: liftView.bounds, cornerWidth: BowBrand.radiusSmall, cornerHeight: BowBrand.radiusSmall,
            transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLift()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    /// The color behind the row now: Card when selected, Hover when hovered, none otherwise.
    var liftColor: NSColor? {
        if isSelected { return BowBrand.card }
        if isHovered { return BowBrand.hover }
        return nil
    }

    private func updateLift() {
        guard let layer = liftView.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = liftColor?.cgColor
        }
        layer.shadowOpacity = isSelected ? Self.shadowOpacity : 0
    }
}

/// The rounded rect a sidebar row lifts on. It never takes a click: the outline handles clicks on its rows.
@MainActor
final class SidebarRowLift: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = BowBrand.radiusSmall
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowRadius = SidebarRowView.shadowRadius
        layer.shadowOffset = SidebarRowView.shadowOffset
        layer.shadowOpacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
