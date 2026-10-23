import AppKit
import BowCore

/// The URL field at the top of the sidebar: a rounded field showing the shown tab's site (`AddressDisplay`), or
/// "Search or type a URL" when it has none, behind a lock symbol. A click opens the command bar on the current address,
/// as Cmd+L does (with no tab shown, the command bar opens to a new tab). View > Hide Toolbar hides it with the top
/// row (`AppSettings.showsToolbar`).
@MainActor
final class URLField: NSObject, SidebarAccessory {
    static var placement: SidebarAccessoryPlacement { .top }

    let field = URLFieldView()
    /// The field with the sidebar's side padding around it and the gap below it.
    let view: NSView = FullWidthView()

    override init() {
        super.init()
        field.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: BowBrand.sidebarLeading),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -BowBrand.sidebarTrailing),
            field.topAnchor.constraint(equalTo: view.topAnchor),
            field.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -BowBrand.sidebarGap),
            field.heightAnchor.constraint(equalToConstant: URLFieldView.height),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(toolbarVisibilityChanged(_:)), name: AppSettings.toolbarVisibilityChanged,
            object: nil)
        view.isHidden = !AppSettings.showsToolbar
    }

    func update(content: SidebarContent, context: (any SidebarActionContext)?) {
        let url = content.activeItem.flatMap { content.tabs[$0]?.url }
        field.show(AddressDisplay.text(for: url))
    }

    @objc private func toolbarVisibilityChanged(_ notification: Notification) {
        view.isHidden = !AppSettings.showsToolbar
    }
}

/// A view as wide as the view holding it. The sidebar's slot is a stack view that takes a hidden view out of its
/// layout; once shown again, the slot alone gives it only its fitting width, so it pins its own width each time it
/// joins a view.
@MainActor
private final class FullWidthView: NSView {
    private var widthConstraints: [NSLayoutConstraint] = []

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NSLayoutConstraint.deactivate(widthConstraints)
        widthConstraints = []
        guard let superview else { return }
        widthConstraints = [
            leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor),
        ]
        NSLayoutConstraint.activate(widthConstraints)
    }
}

/// The field itself: 36 high, corner radius 10, the Active fill, a 13 point lock in the Soft color (a crossed lock in
/// Jam Deep while the page is not secure) and one line of text in the UI font, cut at the end when it does not fit. It acts like a button: a click sends
/// `CommandBarFeature.openFromURLField(_:)` up the responder chain, so it reaches the window's command bar.
@MainActor
final class URLFieldView: NSView {
    static let height: CGFloat = 36
    static let lockSize: CGFloat = 13

    private let lock = NSImageView()
    private let label = NSTextField(labelWithString: AddressDisplay.placeholder)
    /// The address text shown, nil while the placeholder shows.
    private(set) var address: String?
    /// True between a mouse down and its mouse up.
    private var isPressed = false

    /// What the field shows now: the address, or the placeholder.
    var text: String { label.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        lock.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.lockSize, weight: .regular)
        lock.setContentHuggingPriority(.required, for: .horizontal)
        lock.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.font = BowBrand.ui()
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [lock, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            lock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            lock.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Opens the command bar on the current address")
        show(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The tab's own address, as last given to `show(_:)`.
    private var tabAddress: String?
    /// What the window's certificate error page puts in the field while the shown tab shows it (the address that
    /// failed, not secure), in place of the tab's own address; nil otherwise. Set by `CertificateErrorFeature`.
    var certificateLine: AddressLine? {
        didSet { if certificateLine != oldValue { render() } }
    }

    /// True while the field marks its page not secure.
    private(set) var isNotSecure = false

    /// Shows `address`, or the placeholder when it is nil, unless `certificateLine` stands in for it.
    func show(_ address: String?) {
        tabAddress = address
        render()
    }

    private func render() {
        let line = certificateLine ?? AddressLine(text: tabAddress)
        address = line.text
        isNotSecure = line.security == .notSecure
        let text = line.text ?? AddressDisplay.placeholder
        label.stringValue = text
        label.textColor = line.text == nil ? BowBrand.soft : BowBrand.text
        lock.image = NSImage(
            systemSymbolName: isNotSecure ? "lock.slash.fill" : "lock.fill",
            accessibilityDescription: isNotSecure ? "Not secure" : nil)
        lock.contentTintColor = isNotSecure ? BowBrand.button : BowBrand.soft
        toolTip = isNotSecure ? "Not secure: \(text)" : line.text
        setAccessibilityLabel(isNotSecure ? "Not secure, \(text)" : text)
    }

    // MARK: Clicking

    /// A drag on the field never moves the window, as a click on a control does not.
    override var mouseDownCanMoveWindow: Bool { false }

    /// The whole field takes the click, its lock and text included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }

    /// Opens the command bar through the responder chain from this view: the window, its controller, then the
    /// window's features, the command bar among them.
    private func open() {
        _ = tryToPerform(#selector(CommandBarFeature.openFromURLField(_:)), with: self)
    }

    // MARK: Drawing

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = BowBrand.active.cgColor
        }
        layer?.cornerRadius = BowBrand.radiusCard
        layer?.cornerCurve = .continuous
    }
}
