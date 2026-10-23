import AppKit
import BowCore

/// The find in page bar: a search field, the "n of m" count and previous, next and done buttons, floating at the
/// top right corner of the page. It only shows and reports; the window controller runs the searches.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    /// Called with the field's text whenever it changes.
    var onTextChange: ((String) -> Void)?
    /// Called to step to the next match (true) or the previous one (false): Enter, Shift+Enter or the buttons.
    var onStep: ((_ forward: Bool) -> Void)?
    /// Called when the bar asks to close: Escape or the done button.
    var onClose: (() -> Void)?

    let field = FindField()
    /// Shows "n of m" for the last result, and nothing before the first one.
    let countLabel = NSTextField(labelWithString: "")

    var text: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        self.shadow = shadow

        field.placeholderString = "Find in page"
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.setAccessibilityLabel("Find in page")
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.alignment = .right

        let previous = Self.button("chevron.up", "Previous match", #selector(stepBackward))
        let next = Self.button("chevron.down", "Next match", #selector(stepForward))
        let done = Self.button("xmark", "Close find bar", #selector(close))
        for button in [previous, next, done] { button.target = self }

        let stack = NSStackView(views: [field, countLabel, previous, next, done])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Shows `result` as "n of m", or clears the count when nil.
    func show(_ result: FindResult?) {
        countLabel.stringValue = result.map { "\($0.activeMatch) of \($0.matchCount)" } ?? ""
    }

    /// Puts the keyboard in the field with its text selected, so typing replaces the last search.
    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private static func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = label
        return button
    }

    @objc private func stepForward() { onStep?(true) }
    @objc private func stepBackward() { onStep?(false) }
    @objc private func close() { onClose?() }

    func controlTextDidChange(_ notification: Notification) {
        onTextChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // The text system sends the same command for Return and Shift+Return; the field editor saw which.
            let shift = (textView as? FindFieldEditor)?.keyModifiers.contains(.shift) ?? false
            onStep?(!shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Instead of the search field's default, which only empties it.
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// The find bar's search field, edited with a `FindFieldEditor`.
final class FindField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { FindFieldCell.self }
        set {}
    }
}

private final class FindFieldCell: NSSearchFieldCell {
    private var editor: FindFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if let editor { return editor }
        let editor = FindFieldEditor()
        editor.isFieldEditor = true
        self.editor = editor
        return editor
    }
}

/// A field editor that remembers the modifier keys of the key press it is handling, so the find bar can tell
/// Shift+Return from Return.
final class FindFieldEditor: NSTextView {
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        defer { keyModifiers = [] }
        super.keyDown(with: event)
    }
}
