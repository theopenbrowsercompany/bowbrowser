import AppKit

/// A shadow under the page card (see `BrowserWindowController.pageShadow`): its color (opacity included), blur
/// radius and offset (AppKit's, so a negative height is down), and the `fill` of the rounded rect that casts it.
struct PageShadow: Equatable {
    var color: NSColor
    var radius: CGFloat
    var offset: NSSize
    var fill: NSColor
}

/// The view behind the page area that draws the page shadow: a rounded rect in the page's fill with a CALayer shadow
/// whose path is that rounded rect, so the shadow needs no offscreen pass. It never takes a click.
@MainActor
final class PageShadowContainer: NSView {
    private var cornerRadius: CGFloat = 0

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ pageShadow: PageShadow, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        layer?.cornerRadius = cornerRadius
        layer?.backgroundColor = pageShadow.fill.cgColor
        let shadow = NSShadow()
        shadow.shadowColor = pageShadow.color
        shadow.shadowBlurRadius = pageShadow.radius
        shadow.shadowOffset = pageShadow.offset
        self.shadow = shadow
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
