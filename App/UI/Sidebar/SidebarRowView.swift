import AppKit

/// The row view behind each sidebar item: the active tab's row is a lifted Active colored rounded rect with the
/// brand's soft shadow, a hovered row gets the Pin tint, and every other row has no background. The outline's own
/// selection highlight is not drawn, and the row is never emphasized, so titles keep their own color when selected.
@MainActor
final class SidebarRowView: NSTableRowView {
    /// The rounded rect behind the row's cell, below it.
    let liftView = SidebarRowLift()
    private var isHovered = false {
        didSet { updateLift() }
    }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The lift view stands for the selection, so the system's highlight is not drawn.
        selectionHighlightStyle = .none
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
        // Within the sidebar's padding.
        var frame = bounds
        frame.origin.x += BowBrand.sidebarLeading
        frame.size.width = max(frame.width - BowBrand.sidebarLeading - BowBrand.sidebarTrailing, 0)
        liftView.frame = frame
        liftView.layer?.shadowPath = CGPath(
            roundedRect: liftView.bounds, cornerWidth: BowBrand.radiusRow, cornerHeight: BowBrand.radiusRow,
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

    /// Lights or clears the hover for where the pointer is now, for when rows moved under it (a scroll) without
    /// the tracking area seeing it enter or leave.
    func refreshHover() {
        isHovered = Self.pointerIsOver(self)
    }

    /// Whether the pointer is over `view`'s visible part, in a window that is on screen.
    static func pointerIsOver(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor else { return false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return view.visibleRect.contains(point)
    }

    /// The color behind the row now: Active when selected, Pin when hovered, none otherwise.
    var liftColor: NSColor? {
        if isSelected { return BowBrand.active }
        if isHovered { return BowBrand.pin }
        return nil
    }

    private func updateLift() {
        guard let layer = liftView.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = liftColor?.cgColor
        }
        liftView.shadow = isSelected ? BowBrand.softShadow() : nil
    }
}

/// The rounded rect a sidebar row lifts on. It never takes a click: the outline handles clicks on its rows.
@MainActor
final class SidebarRowLift: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = BowBrand.radiusRow
        layer.cornerCurve = .continuous
        layer.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
