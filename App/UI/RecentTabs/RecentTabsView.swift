import AppKit
import BowCore

/// The Ctrl+Tab switcher's panel: the recent tabs, newest first, each with its icon, title and Space, with one row
/// highlighted. It floats over the page card on a White rounded panel, as the command bar does, and takes no clicks
/// and no keyboard: the window's `RecentTabsFeature` drives it.
@MainActor
final class RecentTabsPanel: NSView {
    static let width: CGFloat = 480
    /// The most rows shown at once; a longer list scrolls to keep the highlighted row in view.
    static let maxVisibleRows = 12

    private let content = NSView()
    private let rowStack = NSStackView()
    private(set) var rows: [RecentTabRowView] = []
    /// Every row of the list, in order, and the highlighted one.
    private var all: [(row: RecentTabRow, icon: NSImage?)] = []
    private var selected = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = BowBrand.softShadow()
        content.wantsLayer = true
        if let layer = content.layer {
            layer.backgroundColor = BowBrand.page.cgColor
            layer.cornerRadius = BowBrand.radiusPanel
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        rowStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rowStack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: content.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel("Recent tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: BowBrand.radiusPanel, cornerHeight: BowBrand.radiusPanel, transform: nil)
    }

    /// The panel takes no clicks: they reach the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `list` with the row at `selected` highlighted.
    func show(_ list: [(row: RecentTabRow, icon: NSImage?)], selected: Int) {
        all = list
        self.selected = selected
        rebuild()
    }

    func select(_ index: Int) {
        selected = index
        rebuild()
    }

    private func rebuild() {
        for row in rows { row.removeFromSuperview() }
        let count = all.count
        let visible = min(count, Self.maxVisibleRows)
        let first = max(0, min(selected - visible / 2, count - visible))
        rows = (first..<(first + visible)).map { index in
            let view = RecentTabRowView(row: all[index].row, icon: all[index].icon)
            view.isSelected = index == selected
            return view
        }
        for row in rows {
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor, constant: -16).isActive = true
        }
    }
}

/// One line: the site icon, the title, and the Space the tab lives in at the right.
@MainActor
final class RecentTabRowView: NSView {
    let row: RecentTabRow
    let titleLabel: NSTextField
    let spaceLabel: NSTextField

    var isSelected = false {
        didSet { updateColors() }
    }

    init(row: RecentTabRow, icon: NSImage?) {
        self.row = row
        titleLabel = NSTextField(labelWithString: row.title)
        spaceLabel = NSTextField(labelWithString: row.space?.label ?? "")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = BowBrand.radiusRow
        layer?.cornerCurve = .continuous
        titleLabel.font = BowBrand.ui(14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spaceLabel.font = BowBrand.ui(12)
        spaceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let image = NSImageView(
            image: icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        image.contentTintColor = BowBrand.soft
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true
        image.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let stack = NSStackView(views: [image, titleLabel, spaceLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.distribution = .fill
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(
            [row.title, row.space?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateColors() {
        layer?.backgroundColor = (isSelected ? BowBrand.pin : NSColor.clear).cgColor
        titleLabel.textColor = BowBrand.text
        spaceLabel.textColor = BowBrand.soft
    }
}
