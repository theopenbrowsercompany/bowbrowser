import AppKit
import BowCore

/// The command bar's views: a clear layer over the whole window that closes the bar on a click outside it, holding
/// the floating panel (a text field over one list of results) centered over the page. They only show and report;
/// the window's `CommandBarFeature` runs the queries and carries out the choice.
@MainActor
final class CommandBarOverlay: NSView {
    let panel = CommandBarPanel()
    /// Called on a mouse down anywhere outside the panel.
    var onClickOutside: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Every point outside the panel is the overlay's, so the page and the sidebar under it get no clicks while the
    /// bar shows.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if panel.frame.contains(local) { return panel.hitTest(convert(local, to: panel.superview)) ?? panel }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onClickOutside?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClickOutside?()
    }
}

/// The floating panel: the field and up to `CommandBarRanker.maxResults` rows, on a White rounded panel with the
/// brand's soft shadow. It sits over the page card, which is White in both appearances, so it always draws light.
@MainActor
final class CommandBarPanel: NSView, NSTextFieldDelegate {
    static let width: CGFloat = 640

    let field = NSTextField()
    private let rowStack = NSStackView()
    private let separator = NSBox()
    private(set) var rows: [CommandBarRowView] = []

    /// Called with the field's text whenever the person changes it.
    var onTextChange: ((String) -> Void)?
    /// Called with -1 for Up and 1 for Down.
    var onMove: ((Int) -> Void)?
    /// Called on Enter in the field.
    var onEnter: (() -> Void)?
    /// Called with the index of a row that was clicked.
    var onClickRow: ((Int) -> Void)?
    /// Called on Escape in the field.
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        if let layer {
            layer.backgroundColor = BowBrand.page.cgColor
            layer.cornerRadius = BowBrand.radiusPanel
            layer.cornerCurve = .continuous
        }
        shadow = BowBrand.softShadow()

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = "Search or enter address"
        field.setAccessibilityLabel("Command bar")
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        separator.boxType = .separator
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2

        let stack = NSStackView(views: [field, separator, rowStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 10, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            rowStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `results`, highlighting the row at `selected`.
    func show(_ results: [CommandBarResult], selected: Int?) {
        for row in rows { row.removeFromSuperview() }
        rows = results.enumerated().map { index, result in
            let row = CommandBarRowView(result: result)
            row.isSelected = index == selected
            row.onClick = { [weak self] in self?.onClickRow?(index) }
            return row
        }
        for row in rows {
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        separator.isHidden = rows.isEmpty
    }

    func select(_ index: Int?) {
        for (offset, row) in rows.enumerated() { row.isSelected = offset == index }
    }

    func controlTextDidChange(_ obj: Notification) {
        onTextChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            onMove?(-1)
        case #selector(NSResponder.moveDown(_:)):
            onMove?(1)
        case #selector(NSResponder.insertNewline(_:)):
            onEnter?()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }
}

/// One result: its title and address, and for an open tab a "Switch to Tab" mark with the Space it lives in.
@MainActor
final class CommandBarRowView: NSView {
    let result: CommandBarResult
    let titleLabel: NSTextField
    let detailLabel: NSTextField
    /// "Switch to Tab", with the Space's icon and name when it has one; empty for other results.
    let badgeLabel: NSTextField
    var onClick: (() -> Void)?

    var isSelected = false {
        didSet { updateColors() }
    }

    init(result: CommandBarResult) {
        self.result = result
        titleLabel = NSTextField(labelWithString: Self.title(of: result))
        detailLabel = NSTextField(labelWithString: Self.detail(of: result))
        badgeLabel = NSTextField(labelWithString: Self.badge(of: result))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 12)
        badgeLabel.font = .systemFont(ofSize: 12)
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let stack = NSStackView(views: [text, badgeLabel])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            [titleLabel.stringValue, badgeLabel.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func updateColors() {
        layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        detailLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        badgeLabel.textColor = isSelected ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    private static func title(of result: CommandBarResult) -> String {
        switch result.kind {
        case .search: "Search for \u{201C}\(result.title)\u{201D}"
        case .openTab, .history, .navigation: result.title.isEmpty ? result.url.absoluteString : result.title
        }
    }

    private static func detail(of result: CommandBarResult) -> String {
        switch result.kind {
        case .search: ""
        case .openTab, .history, .navigation: result.url.absoluteString
        }
    }

    private static func badge(of result: CommandBarResult) -> String {
        guard case .openTab = result.kind else { return "" }
        guard let space = result.space else { return "Switch to Tab" }
        // An emoji shows as text; a symbol icon needs an image, so its row shows the name alone.
        let emoji = space.icon.flatMap { $0.kind == .emoji ? $0.value : nil }
        let name = [emoji, space.name].compactMap { $0 }.joined(separator: " ")
        return "Switch to Tab \u{00B7} \(name)"
    }
}
