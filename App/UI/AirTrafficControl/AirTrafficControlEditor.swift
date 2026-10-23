import AppKit
import BowCore

/// The Air Traffic Control window (Bow > Air Traffic Control…): the routing rules in order, each a match on the
/// link's address (any address, contains, or matches a regular expression), an optional source app by bundle
/// identifier, and where the link opens. Buttons add and remove rules and move the selected one up or down (the first
/// rule that matches wins). Below sit where links go when no rule matches, where links with no source app go, and the
/// app the last link came from, so the person can copy its bundle identifier into a rule. Every change is saved at
/// once.
///
/// Standard AppKit controls only: a view-based table with text fields and pop-up buttons.
@MainActor
final class AirTrafficControlEditor: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Column: String, CaseIterable {
        case match, pattern, source, destination

        var title: String {
            switch self {
            case .match: "If the address"
            case .pattern: "Text"
            case .source: "From app (bundle ID)"
            case .destination: "Open in"
            }
        }

        var width: CGFloat {
            switch self {
            case .match: 130
            case .pattern: 220
            case .source: 200
            case .destination: 180
            }
        }
    }

    /// The match pop-up's items, in order: any address (no URL condition), contains, matches.
    private static let matchTitles = ["is any address", "contains", "matches"]

    private unowned let control: AirTrafficControl
    private let choices: () -> [AirTrafficControl.Choice]
    private var onClosed: ((AirTrafficControlEditor) -> Void)?
    private var table: RoutingTable

    let tableView = NSTableView()
    let addButton = NSButton(title: "Add Rule", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let upButton = NSButton(title: "Move Up", target: nil, action: nil)
    let downButton = NSButton(title: "Move Down", target: nil, action: nil)
    let defaultPopUp = NSPopUpButton()
    let noSourcePopUp = NSPopUpButton()
    let lastSourceLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")

    /// `keepsFrame` keeps the window at `frame` even off every screen (e2e runs); otherwise AppKit keeps it on screen.
    init(
        frame: NSRect, keepsFrame: Bool = false, control: AirTrafficControl,
        choices: @escaping () -> [AirTrafficControl.Choice], onClosed: @escaping (AirTrafficControlEditor) -> Void
    ) {
        self.control = control
        self.choices = choices
        self.onClosed = onClosed
        table = control.table
        let window = AirTrafficControlWindow(
            contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
            defer: false)
        window.keepsFrame = keepsFrame
        // AppKit pulls a new titled window onto a screen before `keepsFrame` is set; put it back where it was asked.
        if keepsFrame { window.setFrame(window.frameRect(forContentRect: frame), display: false) }
        window.title = "Air Traffic Control"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 320)
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        build(in: window)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(takesFocus: Bool) {
        if takesFocus {
            showWindow(nil)
            NSApp.activate()
        } else {
            window?.orderFront(nil)
        }
    }

    /// A link arrived: shows the app it came from.
    func sourceChanged() {
        lastSourceLabel.stringValue = LinkRouting.lastSourceLine(arrived: control.lastSource)
    }

    /// The rules changed elsewhere: shows them.
    func tableReplaced() {
        table = control.table
        reload()
    }

    func windowWillClose(_ notification: Notification) {
        endEditing()
        let closed = onClosed
        onClosed = nil
        closed?(self)
    }

    // MARK: Layout

    private func build(in window: NSWindow) {
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 26
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for (button, action) in [
            (addButton, #selector(addRule(_:))), (removeButton, #selector(removeRule(_:))),
            (upButton, #selector(moveRuleUp(_:))), (downButton, #selector(moveRuleDown(_:))),
        ] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        defaultPopUp.target = self
        defaultPopUp.action = #selector(defaultChanged(_:))
        noSourcePopUp.target = self
        noSourcePopUp.action = #selector(noSourceChanged(_:))
        lastSourceLabel.isSelectable = true
        lastSourceLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor

        let intro = NSTextField(
            wrappingLabelWithString:
                "Links from other apps open where the first matching rule says. Leave the text or the app empty to "
                + "match any.")
        let buttons = NSStackView(views: [addButton, removeButton, NSView(), upButton, downButton])
        buttons.orientation = .horizontal
        let defaultRow = Self.row("When no rule matches, open in:", defaultPopUp)
        let noSourceRow = Self.row("Links with no source app open in:", noSourcePopUp)
        let stack = NSStackView(views: [intro, scroll, buttons, defaultRow, noSourceRow, lastSourceLabel, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    private static func row(_ title: String, _ popUp: NSPopUpButton) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: title), popUp])
        row.orientation = .horizontal
        return row
    }

    // MARK: Content

    /// Rebuilds everything from `table`.
    private func reload() {
        tableView.reloadData()
        let options = choices()
        Self.fill(defaultPopUp, with: options, selecting: table.defaultDestination, extra: nil)
        Self.fill(noSourcePopUp, with: options, selecting: table.noSourceDestination, extra: "Same as no match")
        sourceChanged()
        updateButtons()
        updateStatus(saveProblem: nil)
    }

    /// Fills `popUp` with `options` (plus a first item `extra` standing for nil) and selects `selected`. A destination
    /// that is gone (a deleted Space or profile) shows as a disabled item, so the person sees what the rule names.
    private static func fill(
        _ popUp: NSPopUpButton, with options: [AirTrafficControl.Choice], selecting selected: RouteDestination?,
        extra: String?
    ) {
        popUp.removeAllItems()
        popUp.autoenablesItems = false
        if let extra {
            popUp.addItem(withTitle: extra)
            popUp.lastItem?.representedObject = nil
        }
        for option in options {
            popUp.addItem(withTitle: option.title)
            popUp.lastItem?.representedObject = DestinationBox(option.destination)
        }
        guard let selected else {
            popUp.selectItem(at: 0)
            return
        }
        if let index = options.firstIndex(where: { $0.destination == selected }) {
            popUp.selectItem(at: index + (extra == nil ? 0 : 1))
        } else {
            popUp.addItem(withTitle: "Missing: \(missingTitle(selected))")
            popUp.lastItem?.representedObject = DestinationBox(selected)
            popUp.lastItem?.isEnabled = false
            popUp.select(popUp.lastItem)
        }
    }

    private static func missingTitle(_ destination: RouteDestination) -> String {
        switch destination {
        case .space(let id): "Space \(id)"
        case .profile(let id): "Profile \(id)"
        case .littleArc: "Little Arc"
        case .mostRecentWindow: "Most recent window"
        }
    }

    private static func destination(of popUp: NSPopUpButton) -> RouteDestination? {
        (popUp.selectedItem?.representedObject as? DestinationBox)?.destination
    }

    private func updateButtons() {
        let row = tableView.selectedRow
        removeButton.isEnabled = row >= 0
        upButton.isEnabled = row > 0
        downButton.isEnabled = row >= 0 && row < table.rules.count - 1
    }

    /// The line under the controls: why changes are not saved, then the rules that cannot match, and why.
    private func updateStatus(saveProblem: String?) {
        var lines: [String] = []
        if let reason = control.readOnlyReason {
            lines.append(reason)
        } else if let saveProblem {
            lines.append(saveProblem)
        }
        for invalid in table.invalidRules {
            guard let index = table.rules.firstIndex(where: { $0.id == invalid.rule }) else { continue }
            lines.append("Rule \(index + 1) never matches: \(invalid.problem).")
        }
        for shadowed in table.shadowedRules {
            guard let index = table.rules.firstIndex(where: { $0.id == shadowed.rule }),
                let earlier = table.rules.firstIndex(where: { $0.id == shadowed.shadowedBy })
            else { continue }
            lines.append("Rule \(index + 1) never matches: rule \(earlier + 1) above it matches the same links.")
        }
        statusLabel.stringValue = lines.joined(separator: "\n")
    }

    /// Ends the edit in a text cell, which saves what was typed (the cell sends its action when editing ends). Called
    /// before anything that reloads the table or closes the window, so typed text is never lost.
    private func endEditing() {
        window?.makeFirstResponder(nil)
    }

    /// The view in `row`'s `column` (0 match, 1 text, 2 app, 3 destination).
    func cellView(row: Int, column: Int) -> NSView? {
        tableView.view(atColumn: column, row: row, makeIfNecessary: true)
    }

    /// Saves `table` and refreshes what depends on it.
    private func commit(reloadTable: Bool = false, select row: Int? = nil) {
        let problem = control.update(table, from: self)
        if reloadTable { tableView.reloadData() }
        if let row { tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        updateButtons()
        updateStatus(saveProblem: problem)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { table.rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
            table.rules.indices.contains(row)
        else { return nil }
        let rule = table.rules[row]
        switch column {
        case .match:
            let popUp = NSPopUpButton()
            popUp.addItems(withTitles: Self.matchTitles)
            popUp.selectItem(at: rule.urlPattern.map { $0.style == .contains ? 1 : 2 } ?? 0)
            popUp.target = self
            popUp.action = #selector(matchChanged(_:))
            popUp.controlSize = .small
            return popUp
        case .pattern:
            let field = NSTextField(string: rule.urlPattern?.text ?? "")
            field.placeholderString = rule.urlPattern == nil ? "any address" : "github.com"
            field.isEnabled = rule.urlPattern != nil
            field.target = self
            field.action = #selector(patternChanged(_:))
            field.cell?.sendsActionOnEndEditing = true
            return field
        case .source:
            let field = NSTextField(string: rule.sourceApp ?? "")
            field.placeholderString = "any app"
            field.target = self
            field.action = #selector(sourceAppChanged(_:))
            field.cell?.sendsActionOnEndEditing = true
            return field
        case .destination:
            let popUp = NSPopUpButton()
            popUp.controlSize = .small
            Self.fill(popUp, with: choices(), selecting: rule.destination, extra: nil)
            popUp.target = self
            popUp.action = #selector(destinationChanged(_:))
            return popUp
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Actions

    @objc func addRule(_ sender: Any?) {
        endEditing()
        // A new rule matches on the address and opens in the most recent window until the person picks otherwise.
        table.rules.append(RoutingRule(urlPattern: URLPattern(.contains, ""), destination: .mostRecentWindow))
        commit(reloadTable: true, select: table.rules.count - 1)
    }

    @objc func removeRule(_ sender: Any?) {
        endEditing()
        let row = tableView.selectedRow
        guard table.rules.indices.contains(row) else { return }
        table.rules.remove(at: row)
        commit(reloadTable: true, select: table.rules.isEmpty ? nil : min(row, table.rules.count - 1))
    }

    @objc func moveRuleUp(_ sender: Any?) {
        move(by: -1)
    }

    @objc func moveRuleDown(_ sender: Any?) {
        move(by: 1)
    }

    /// Moves the selected rule by `offset` places, keeping it selected.
    func move(by offset: Int) {
        endEditing()
        let row = tableView.selectedRow
        let target = row + offset
        guard table.rules.indices.contains(row), table.rules.indices.contains(target) else { return }
        table.rules.swapAt(row, target)
        commit(reloadTable: true, select: target)
    }

    @objc private func matchChanged(_ sender: NSPopUpButton) {
        endEditing()
        let row = tableView.row(for: sender)
        guard table.rules.indices.contains(row) else { return }
        let text = table.rules[row].urlPattern?.text ?? ""
        switch sender.indexOfSelectedItem {
        case 1: table.rules[row].urlPattern = URLPattern(.contains, text)
        case 2: table.rules[row].urlPattern = URLPattern(.matches, text)
        default: table.rules[row].urlPattern = nil
        }
        commit(reloadTable: true, select: row)
    }

    @objc private func patternChanged(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        guard table.rules.indices.contains(row), let style = table.rules[row].urlPattern?.style else { return }
        table.rules[row].urlPattern = URLPattern(style, sender.stringValue.trimmingCharacters(in: .whitespaces))
        commit()
    }

    @objc private func sourceAppChanged(_ sender: NSTextField) {
        let row = tableView.row(for: sender)
        guard table.rules.indices.contains(row) else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        table.rules[row].sourceApp = text.isEmpty ? nil : text
        commit()
    }

    @objc private func destinationChanged(_ sender: NSPopUpButton) {
        endEditing()
        let row = tableView.row(for: sender)
        guard table.rules.indices.contains(row), let destination = Self.destination(of: sender) else { return }
        table.rules[row].destination = destination
        commit()
    }

    @objc private func defaultChanged(_ sender: NSPopUpButton) {
        endEditing()
        guard let destination = Self.destination(of: sender) else { return }
        table.defaultDestination = destination
        commit()
    }

    @objc private func noSourceChanged(_ sender: NSPopUpButton) {
        endEditing()
        table.noSourceDestination = Self.destination(of: sender)
        commit()
    }

    // MARK: Reading back

    /// What row `row` shows, cell by cell: the match item, the text, the app and the destination's title.
    func shownRow(_ row: Int) -> [String] {
        Column.allCases.enumerated().map { index, _ in
            switch tableView.view(atColumn: index, row: row, makeIfNecessary: true) {
            case let popUp as NSPopUpButton: popUp.titleOfSelectedItem ?? ""
            case let field as NSTextField: field.stringValue
            default: ""
            }
        }
    }
}

/// The editor's window, which can keep a frame off every screen.
final class AirTrafficControlWindow: NSWindow {
    var keepsFrame = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        keepsFrame ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// A destination as a menu item's represented object.
private final class DestinationBox: NSObject {
    let destination: RouteDestination

    init(_ destination: RouteDestination) {
        self.destination = destination
    }
}
