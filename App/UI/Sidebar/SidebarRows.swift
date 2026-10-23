import AppKit
import BowCore

/// One tab's row in the sidebar.
@MainActor
final class TabSidebarRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TabSidebarRow")

    let titleField = NSTextField(labelWithString: "")
    let iconView = NSImageView()
    let spinner = NSProgressIndicator()
    let closeButton: NSButton
    /// Holds the row's accessory view (`SidebarRowAccessory`) before the close button; empty, it takes no room.
    private let accessorySlot = NSStackView()
    var onClose: (() -> Void)?
    /// The view a row accessory provider gave this row, nil for none. Read from the slot itself, so a view a
    /// provider moved to another row is no longer this row's.
    var accessoryView: NSView? {
        get { accessorySlot.arrangedSubviews.first }
        set {
            let current = accessorySlot.arrangedSubviews.first
            guard newValue !== current else { return }
            current?.removeFromSuperview()
            if let newValue { accessorySlot.addArrangedSubview(newValue) }
        }
    }
    var isActive = false {
        didSet { updateCloseButton() }
    }
    /// False hides the close button for good (a row whose item cannot be closed from the sidebar).
    var isClosable = true {
        didSet { updateCloseButton() }
    }
    private var isHovered = false {
        didSet { updateCloseButton() }
    }

    init() {
        let xmark = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab") ?? NSImage()
        closeButton = NSButton(image: xmark, target: nil, action: nil)
        super.init(frame: .zero)
        identifier = Self.identifier

        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: 13)
        titleField.cell?.usesSingleLineMode = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleField

        iconView.imageScaling = .scaleProportionallyUpOrDown
        imageView = iconView

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")

        accessorySlot.orientation = .horizontal
        accessorySlot.spacing = 2
        accessorySlot.setHuggingPriority(.required, for: .horizontal)
        let emptySlotWidth = accessorySlot.widthAnchor.constraint(equalToConstant: 0)
        // Above the title's hugging, so a short title keeps its width without the layout being ambiguous.
        emptySlotWidth.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 1)

        for view in [iconView, spinner, titleField, accessorySlot, closeButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: accessorySlot.leadingAnchor, constant: -4),
            accessorySlot.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            accessorySlot.centerYAnchor.constraint(equalTo: centerYAnchor),
            // An empty stack view may add no width of its own, so these keep a long title clear of the close button
            // whatever the slot holds (which also keeps the slot from going below no width), and the empty slot
            // shrinks to nothing.
            emptySlotWidth,
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `tab`: its icon (or a spinner while loading, or a globe without an icon) and its title.
    func show(_ tab: BrowserTab, favicon: NSImage?, isActive: Bool) {
        titleField.stringValue = Self.displayTitle(of: tab)
        toolTip = titleField.stringValue
        iconView.image =
            favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.contentTintColor = favicon == nil ? .secondaryLabelColor : nil
        hasFavicon = favicon != nil
        if tab.isLoading {
            iconView.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            iconView.isHidden = false
        }
        isLoading = tab.isLoading
        self.isActive = isActive
    }

    /// True while the row shows the spinner.
    private(set) var isLoading = false
    /// True while the row shows the site's own icon rather than the placeholder.
    private(set) var hasFavicon = false

    /// The page title, or its address before it has one, or "New Tab" before anything loaded.
    static func displayTitle(of tab: BrowserTab) -> String {
        if !tab.title.isEmpty { return tab.title }
        if let url = tab.url { return url.host ?? url.absoluteString }
        return "New Tab"
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    private func updateCloseButton() {
        closeButton.isHidden = !isClosable || !(isActive || isHovered)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Only the row's own area: AppKit adds others (for the tooltip) that must stay.
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    /// The tracking area for hovering, which follows the row's visible rect by itself.
    private var hoverArea: NSTrackingArea?

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        onClose = nil
        // The accessory stays for the outline to offer its provider again (`SidebarRowAccessory`); the outline sets
        // it, or nil, every time it shows the row.
    }
}

/// A folder's or split's row in the sidebar: its symbol and its name, which `beginRename()` makes editable in place.
/// The outline draws its disclosure triangle.
@MainActor
final class SidebarGroupRow: NSTableCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarGroupRow")

    let titleField = NSTextField(labelWithString: "")
    let iconView = NSImageView()
    /// Called with the new name when an edit `beginRename()` started ends with Return or by leaving the field, unless
    /// the name is empty or unchanged. Escape ends the edit without calling it.
    var onRename: ((String) -> Void)?
    /// The name shown when the edit began, restored when it is cancelled.
    private var nameBeforeEdit: String?
    var isRenaming: Bool { nameBeforeEdit != nil }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: 13)
        titleField.cell?.usesSingleLineMode = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = titleField
        iconView.contentTintColor = .secondaryLabelColor
        imageView = iconView
        for view in [iconView, titleField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows folder or split `item`.
    func show(_ item: SidebarItem) {
        if case .split = item.data {
            titleField.stringValue = item.title ?? "Split View"
            iconView.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        } else {
            titleField.stringValue = item.title ?? "Folder"
            iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        }
        toolTip = titleField.stringValue
    }

    /// Makes the name editable in place, all of it selected. Returns false, changing nothing, when the row is not in
    /// a window or the field cannot take the keyboard focus.
    @discardableResult
    func beginRename() -> Bool {
        guard !isRenaming, let window else { return isRenaming }
        nameBeforeEdit = titleField.stringValue
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.delegate = self
        guard window.makeFirstResponder(titleField) else {
            endRename(commit: false)
            return false
        }
        titleField.currentEditor()?.selectAll(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        endRename(commit: false)
        return true
    }

    /// Ends an edit without saving it, putting the old name back: the outline calls it before it reloads the row, so
    /// a reload never saves a half-typed name.
    func cancelRename() {
        endRename(commit: false)
    }

    /// Ends the edit: hands a new, nonempty name to `onRename`, or puts the old name back.
    private func endRename(commit: Bool) {
        guard let old = nameBeforeEdit else { return }
        nameBeforeEdit = nil
        let name = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if titleField.currentEditor() != nil { window?.makeFirstResponder(enclosingScrollView?.documentView) }
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.delegate = nil
        if commit, !name.isEmpty, name != old {
            titleField.stringValue = name
            toolTip = name
            onRename?(name)
        } else {
            titleField.stringValue = old
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        endRename(commit: false)
        onRename = nil
    }
}
