import AppKit
import BowCore

/// What one tab pill shows.
struct TabPillContent {
    var item: SidebarItemID
    var title: String
    var favicon: NSImage?
    var isActive: Bool
}

/// One tab in the top tabs layout's strip: a 190 by 32 pill (`TabStripLayout`) with the site icon, the title in one
/// line and a close button that shows on the active pill and while the pointer is over it. The active pill is lifted
/// (Active fill and the brand's soft shadow) and bold; the others have no fill, and a hovered one gets the Pin tint.
@MainActor
final class TabPillView: NSView {
    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    let closeButton: NSButton
    private(set) var item: SidebarItemID
    private(set) var isActive = false
    var onSelect: ((SidebarItemID) -> Void)?
    var onClose: ((SidebarItemID) -> Void)?
    /// Whether the pointer is over the pill; the tracking area sets it, and a test sets it the same way.
    var isHovered = false {
        didSet {
            updateCloseButton()
            updateFill()
            needsLayout = true
        }
    }
    private var hoverArea: NSTrackingArea?

    init(item: SidebarItemID) {
        self.item = item
        let xmark = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
                .withSymbolConfiguration(xmark) ?? NSImage(),
            target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(TabStripLayout.pillRadius)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        identifier = NSUserInterfaceItemIdentifier("tab-pill")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.usesSingleLineMode = true
        titleField.maximumNumberOfLines = 1
        titleField.textColor = BowBrand.text
        titleField.font = BowBrand.ui(CGFloat(TabStripLayout.titleSize))
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = BowBrand.soft
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")
        closeButton.isHidden = true
        for view in [iconView, titleField, closeButton] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `content`: the icon (a globe without one), the title and whether the pill is the shown tab's.
    func show(_ content: TabPillContent) {
        item = content.item
        isActive = content.isActive
        titleField.stringValue = content.title
        toolTip = content.title
        iconView.image = content.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.contentTintColor = content.favicon == nil ? BowBrand.soft : nil
        titleField.font = BowBrand.ui(CGFloat(TabStripLayout.titleSize), weight: isActive ? .bold : .regular)
        setAccessibilityLabel(content.title)
        setAccessibilityValue(isActive ? "selected" : nil)
        updateCloseButton()
        updateFill()
        needsLayout = true
    }

    /// Whether the close button shows now.
    var closeShown: Bool { isActive || isHovered }

    private func updateCloseButton() {
        closeButton.isHidden = !closeShown
    }

    private func updateFill() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor? = isActive ? BowBrand.active : (isHovered ? BowBrand.pin : nil)
            layer.backgroundColor = color?.cgColor
        }
        shadow = isActive ? BowBrand.softShadow() : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func layout() {
        super.layout()
        let padding = CGFloat(TabStripLayout.pillPadding)
        let icon = CGFloat(TabStripLayout.faviconSize)
        iconView.frame = NSRect(x: padding, y: (bounds.height - icon) / 2, width: icon, height: icon)
        let close: CGFloat = 20
        let closeX = bounds.width - 6 - close
        closeButton.frame = NSRect(x: closeX, y: (bounds.height - close) / 2, width: close, height: close)
        let titleX = padding + icon + 8
        let titleRight = closeShown ? closeX - 4 : bounds.width - padding
        let height = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(
            x: titleX, y: (bounds.height - height) / 2, width: max(titleRight - titleX, 0), height: height)
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: layer?.cornerRadius ?? 0, cornerHeight: layer?.cornerRadius ?? 0,
            transform: nil)
    }

    /// What a press on the pill does: shows its tab.
    func activate() {
        onSelect?(item)
    }

    /// What the close button does: closes the pill's tab.
    @objc func closeClicked(_ sender: Any?) {
        onClose?(item)
    }

    override func mouseDown(with event: NSEvent) {
        activate()
    }

    /// A middle click closes the tab, as in other browsers.
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { closeClicked(nil) } else { super.otherMouseUp(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// A scroll view for the pills that also scrolls sideways under a mouse wheel's vertical turns.
@MainActor
private final class PillScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let document = documentView else {
            super.scrollWheel(with: event)
            return
        }
        let maximum = max(0, document.frame.width - contentView.bounds.width)
        let x = min(max(contentView.bounds.minX - event.scrollingDeltaY, 0), maximum)
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

/// The tab strip row of the top tabs layout: the pills, side by side after the window buttons, then the + button.
/// The pills share the room evenly below their full width (`TabStripLayout.width`); past the minimum width the row
/// scrolls and keeps the shown tab in view. The + button follows the last pill, and stays at the row's end once the
/// pills fill it.
@MainActor
final class TabStripView: NSView {
    private let scroll = PillScrollView()
    private let document = NSView()
    let plusButton: NSButton
    private(set) var pills: [TabPillView] = []
    private var contents: [TabPillContent] = []
    /// The row's leading inset, asked at each layout, as the window buttons may move or leave (full screen).
    var leadingInset: () -> CGFloat = { CGFloat(WindowLayout.rowPadding) }
    var onSelect: ((SidebarItemID) -> Void)?
    var onClose: ((SidebarItemID) -> Void)?
    /// The + button opens the command bar for a new tab, as Cmd+T does.
    var onNewTab: (() -> Void)?
    /// The pills' width and the room they have, as laid out last.
    private(set) var pillWidth = CGFloat(TabStripLayout.pillWidth)
    private(set) var viewportWidth: CGFloat = 0
    private var revealed: SidebarItemID?
    private var revealedViewport: CGFloat = -1

    override init(frame frameRect: NSRect) {
        let symbol = NSImage.SymbolConfiguration(pointSize: CGFloat(TabStripLayout.plusSymbolSize), weight: .regular)
        plusButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")?
                .withSymbolConfiguration(symbol) ?? NSImage(),
            target: nil, action: nil)
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        scroll.documentView = document
        plusButton.isBordered = false
        plusButton.bezelStyle = .regularSquare
        plusButton.imagePosition = .imageOnly
        plusButton.contentTintColor = BowBrand.soft
        plusButton.target = self
        plusButton.action = #selector(plusClicked(_:))
        plusButton.toolTip = "New Tab"
        plusButton.setAccessibilityLabel("New Tab")
        plusButton.identifier = NSUserInterfaceItemIdentifier("tab-strip-plus")
        addSubview(scroll)
        addSubview(plusButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// What the + button does.
    @objc func plusClicked(_ sender: Any?) {
        onNewTab?()
    }

    /// Shows one pill for each of `contents`, in order, reusing the pills of tabs still there.
    func show(_ contents: [TabPillContent]) {
        self.contents = contents
        var byItem: [SidebarItemID: TabPillView] = [:]
        for pill in pills { byItem[pill.item] = pill }
        var next: [TabPillView] = []
        for content in contents {
            let pill = byItem.removeValue(forKey: content.item) ?? makePill(for: content.item)
            pill.show(content)
            next.append(pill)
        }
        for pill in byItem.values { pill.removeFromSuperview() }
        pills = next
        needsLayout = true
    }

    private func makePill(for item: SidebarItemID) -> TabPillView {
        let pill = TabPillView(item: item)
        pill.onSelect = { [weak self] in self?.onSelect?($0) }
        pill.onClose = { [weak self] in self?.onClose?($0) }
        document.addSubview(pill)
        return pill
    }

    /// Passes presses on the empty row through to the window's drag area behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === scroll || hit === scroll.contentView || hit === document ? nil : hit
    }

    override func layout() {
        super.layout()
        let leading = leadingInset()
        let trailing = CGFloat(WindowLayout.rowPadding)
        let gap = CGFloat(TabStripLayout.gap)
        let plus = CGFloat(TabStripLayout.plusButtonSize)
        let height = CGFloat(TabStripLayout.pillHeight)
        let room = max(bounds.width - leading - trailing - gap - plus, 0)
        let count = pills.count
        pillWidth = CGFloat(TabStripLayout.width(count: count, available: Double(room)))
        let content = CGFloat(TabStripLayout.contentWidth(count: count, pillWidth: Double(pillWidth)))
        viewportWidth = min(content, room)
        scroll.frame = NSRect(x: leading, y: 0, width: viewportWidth, height: bounds.height)
        document.frame = NSRect(x: 0, y: 0, width: max(content, viewportWidth), height: bounds.height)
        let y = (bounds.height - height) / 2
        for (index, pill) in pills.enumerated() {
            pill.frame = NSRect(
                x: CGFloat(TabStripLayout.originX(of: index, pillWidth: Double(pillWidth))), y: y, width: pillWidth,
                height: height)
        }
        plusButton.frame = NSRect(
            x: leading + viewportWidth + (count > 0 ? gap : 0), y: (bounds.height - plus) / 2,
            width: plus, height: plus)
        scrollToShownPill()
    }

    /// Keeps the shown tab's pill in view: when it changed or the room did, else only within the content.
    private func scrollToShownPill() {
        let active = contents.firstIndex { $0.isActive }
        let activeItem = active.map { contents[$0].item }
        let current = Double(scroll.contentView.bounds.minX)
        let target: Double
        if let active, activeItem != revealed || viewportWidth != revealedViewport {
            target = TabStripLayout.scrollOffset(
                revealing: active, count: pills.count, pillWidth: Double(pillWidth), viewport: Double(viewportWidth),
                current: current)
        } else {
            target = TabStripLayout.scrollOffset(
                revealing: -1, count: pills.count, pillWidth: Double(pillWidth), viewport: Double(viewportWidth),
                current: current)
        }
        revealed = activeItem
        revealedViewport = viewportWidth
        if abs(target - current) > 0.01 {
            scroll.contentView.scroll(to: NSPoint(x: target, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// How far the pills are scrolled.
    var scrollOffset: CGFloat { scroll.contentView.bounds.minX }
}
