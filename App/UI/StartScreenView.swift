import AppKit
import BowCore

/// One quick link the start screen shows: a Favorite's sidebar item, its name and its site icon when the window has
/// one.
struct StartQuickLink {
    var item: SidebarItemID
    var title: String
    var icon: NSImage?
}

/// The start screen of an empty Space (the styling guide's first mockup), centred in the page card with 26 points
/// between its parts: the Bow mark, a greeting by the time of day, a search pill that opens the command bar, up to six
/// of the profile's Favorites as quick links, and a hint naming the Space. What it shows comes from `StartScreen` in
/// BowCore; nothing on it animates.
@MainActor
final class StartScreenView: NSView {
    static let markSize: CGFloat = 64
    static let gap: CGFloat = 26
    static let pillWidth: CGFloat = 560
    static let pillHeight: CGFloat = 52
    static let tileSize: CGFloat = 56
    static let linkWidth: CGFloat = 76
    static let linkGap: CGFloat = 18
    /// The least room kept between the screen's parts and the card's sides: in a narrow card the pill shrinks, the
    /// greeting and hint truncate, and quick links that do not fit are left out from the end.
    static let margin: CGFloat = 24

    let markView = NSImageView()
    let greetingLabel = NSTextField(labelWithString: "")
    let searchPill = StartSearchPill()
    let linksRow = NSStackView()
    let hintLabel = NSTextField(labelWithString: "")
    private(set) var links: [StartQuickLinkButton] = []
    /// The hour of the day the greeting was chosen for.
    private(set) var greetingHour = 0
    /// Opens Favorite `item` the way its sidebar tile does.
    var openLink: ((SidebarItemID) -> Void)?

    init() {
        super.init(frame: .zero)
        markView.image = NSImage(named: "BowMark")
        markView.imageScaling = .scaleProportionallyUpOrDown
        markView.setAccessibilityLabel("Bow")
        greetingLabel.font = BowBrand.display()
        greetingLabel.textColor = BowBrand.text
        hintLabel.font = BowBrand.ui(13)
        hintLabel.textColor = BowBrand.soft
        for label in [greetingLabel, hintLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        linksRow.orientation = .horizontal
        linksRow.spacing = Self.linkGap
        linksRow.alignment = .top
        linksRow.detachesHiddenViews = true

        let stack = NSStackView(views: [markView, greetingLabel, searchPill, linksRow, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Self.gap
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Below the window's own size (500), so a narrow card shrinks the pill instead of widening the window.
        let pillWidth = searchPill.widthAnchor.constraint(equalToConstant: Self.pillWidth)
        pillWidth.priority = NSLayoutConstraint.Priority(490)
        searchPill.setContentHuggingPriority(.init(1), for: .horizontal)
        searchPill.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        linksRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        var constraints = [
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.margin),
            markView.widthAnchor.constraint(equalToConstant: Self.markSize),
            markView.heightAnchor.constraint(equalToConstant: Self.markSize),
            pillWidth,
            searchPill.widthAnchor.constraint(lessThanOrEqualToConstant: Self.pillWidth),
            searchPill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
        ]
        for view in [greetingLabel, searchPill, linksRow, hintLabel] as [NSView] {
            constraints.append(view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -2 * Self.margin))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the greeting for `hour`, `hint` and `quickLinks` (at most six, already chosen), keeping a link's view
    /// while it stays.
    func show(hour: Int, hint: String, quickLinks: [StartQuickLink]) {
        greetingHour = hour
        greetingLabel.stringValue = StartScreen.Greeting(hour: hour).rawValue
        hintLabel.stringValue = hint
        hintLabel.toolTip = hint
        let existing = Dictionary(links.map { ($0.item, $0) }, uniquingKeysWith: { first, _ in first })
        let next = quickLinks.map { link in existing[link.item] ?? makeLink(for: link.item) }
        for link in links where !next.contains(where: { $0 === link }) { linksRow.removeView(link) }
        for (index, link) in next.enumerated() where linksRow.arrangedSubviews.firstIndex(of: link) != index {
            if link.superview === linksRow { linksRow.removeView(link) }
            linksRow.insertArrangedSubview(link, at: index)
        }
        for (link, value) in zip(next, quickLinks) { link.show(title: value.title, icon: value.icon) }
        links = next
        linksRow.isHidden = next.isEmpty
        fitLinks()
    }

    override func layout() {
        super.layout()
        fitLinks()
    }

    /// Shows as many quick links as fit between the margins, leaving out the last ones in a narrow card.
    private func fitLinks() {
        let room = bounds.width - 2 * Self.margin + Self.linkGap
        let fitting = max(Int(room / (Self.linkWidth + Self.linkGap)), 0)
        for (index, link) in links.enumerated() where link.isHidden != (index >= fitting) {
            link.isHidden = index >= fitting
        }
    }

    private func makeLink(for item: SidebarItemID) -> StartQuickLinkButton {
        let link = StartQuickLinkButton(item: item)
        link.target = self
        link.action = #selector(linkClicked(_:))
        return link
    }

    @objc private func linkClicked(_ sender: StartQuickLinkButton) {
        openLink?(sender.item)
    }
}

/// The start screen's search field: a fully rounded pill with a magnifying glass and "Search or type a URL". It is a
/// button, not a text field: clicking it, or pressing Return or Space while it has focus, opens the command bar as
/// Cmd+T does.
@MainActor
final class StartSearchPill: NSButton {
    static let placeholder = "Search or type a URL"
    let iconView = NSImageView()
    let placeholderLabel = NSTextField(labelWithString: StartSearchPill.placeholder)

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = StartScreenView.pillHeight / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        let symbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        iconView.image = symbol?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        iconView.contentTintColor = BowBrand.soft
        placeholderLabel.font = BowBrand.ui(16)
        placeholderLabel.textColor = BowBrand.soft
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [iconView, placeholderLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(Self.placeholder)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The whole pill takes the click, also over its icon and placeholder.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) { performClick(nil) } else { super.keyDown(with: event) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = BowBrand.search.cgColor
            layer?.borderColor = BowBrand.line.cgColor
        }
    }
}

/// One quick link: a 56 point tile with 16 point corners holding the site's icon, or its name's first letter, at 24
/// points, and the name under it in one truncated line. A click opens the Favorite.
@MainActor
final class StartQuickLinkButton: NSButton {
    let item: SidebarItemID
    let tile = NSView()
    let iconView = NSImageView()
    let letterLabel = NSTextField(labelWithString: "")
    let titleLabel = NSTextField(labelWithString: "")

    init(item: SidebarItemID) {
        self.item = item
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = BowBrand.radiusQuickLink
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 1
        iconView.imageScaling = .scaleProportionallyUpOrDown
        letterLabel.font = BowBrand.ui(24, weight: .semibold)
        letterLabel.textColor = BowBrand.soft
        letterLabel.alignment = .center
        titleLabel.font = BowBrand.ui(12.5)
        titleLabel.textColor = BowBrand.soft
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [tile, titleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [iconView, letterLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(view)
        }
        let side = StartScreenView.tileSize
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: StartScreenView.linkWidth),
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.centerXAnchor.constraint(equalTo: centerXAnchor),
            tile.widthAnchor.constraint(equalToConstant: side),
            tile.heightAnchor.constraint(equalToConstant: side),
            iconView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            letterLabel.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            letterLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.button)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(title: String, icon: NSImage?) {
        titleLabel.stringValue = title
        toolTip = title
        setAccessibilityLabel(title)
        iconView.image = icon
        iconView.isHidden = icon == nil
        letterLabel.isHidden = icon != nil
        letterLabel.stringValue = title.first.map { String($0).uppercased() } ?? "?"
    }

    /// The whole link, tile and name, takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tile.layer?.backgroundColor = BowBrand.search.cgColor
            tile.layer?.borderColor = BowBrand.line.cgColor
        }
    }
}
