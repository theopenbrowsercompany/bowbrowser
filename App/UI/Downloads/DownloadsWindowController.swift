import AppKit
import BowCore

/// The downloads window: every download, newest first, with its progress and pause, resume, cancel and clear
/// buttons, and the "ask where to save" setting. It only shows `DownloadsCenter` and calls its controls.
@MainActor
final class DownloadsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let center: DownloadsCenter
    private let tableView = NSTableView()
    private let askCheckbox = NSButton(checkboxWithTitle: "Ask where to save each file", target: nil, action: nil)

    /// The rows on screen, newest first.
    var rows: [DownloadEntry] { center.list.entries }

    /// Opens the window on `center`, or in `window` when given (e2e runs pass an off-screen one).
    init(center: DownloadsCenter, window givenWindow: NSWindow? = nil) {
        self.center = center
        let window =
            givenWindow
            ?? NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
        window.title = "Downloads"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 200)
        super.init(window: window)
        if givenWindow == nil { window.center() }
        window.contentView = makeContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The view of row `row`, laid out now if it is not yet.
    func rowView(at row: Int) -> DownloadRowView? {
        guard row < tableView.numberOfRows else { return nil }
        return tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? DownloadRowView
    }

    /// Redraws the rows from `center`. The owner calls it on every change.
    func reload() {
        tableView.reloadData()
        askCheckbox.state = DownloadSettings.askWhereToSave ? .on : .off
    }

    private func makeContent() -> NSView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("download"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = DownloadRowView.height
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        askCheckbox.target = self
        askCheckbox.action = #selector(toggleAskWhereToSave(_:))
        askCheckbox.state = DownloadSettings.askWhereToSave ? .on : .off
        askCheckbox.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scrollView)
        content.addSubview(askCheckbox)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            askCheckbox.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            askCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            askCheckbox.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        return content
    }

    @objc private func toggleAskWhereToSave(_ sender: NSButton) {
        DownloadSettings.askWhereToSave = sender.state == .on
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("DownloadRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? DownloadRowView ?? DownloadRowView()
        view.identifier = identifier
        let entry = rows[row]
        view.show(entry)
        view.onPauseOrResume = { [weak self] in
            guard let self, let current = self.center.list.entry(entry.id) else { return }
            if current.item.canPause {
                self.center.pause(current)
            } else if current.item.canResume {
                self.center.resume(current)
            }
        }
        view.onCancelOrClear = { [weak self] in
            guard let self, let current = self.center.list.entry(entry.id) else { return }
            if current.item.canRemove {
                self.center.remove(current)
            } else if current.item.canCancel {
                self.center.cancel(current)
            }
        }
        return view
    }
}

/// One download: its name, a progress bar, the status line, and two buttons (pause or resume, cancel or clear).
@MainActor
final class DownloadRowView: NSTableCellView {
    static let height: CGFloat = 64

    let nameLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onPauseOrResume: (() -> Void)?
    var onCancelOrClear: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: Self.height))
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        for button in [pauseButton, cancelButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        pauseButton.action = #selector(pauseOrResume)
        cancelButton.action = #selector(cancelOrClear)

        let text = NSStackView(views: [nameLabel, progress, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let buttons = NSStackView(views: [pauseButton, cancelButton])
        buttons.spacing = 6
        let row = NSStackView(views: [text, buttons])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
        ])
        buttons.setHuggingPriority(.required, for: .horizontal)
        text.setHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ entry: DownloadEntry) {
        let item = entry.item
        nameLabel.stringValue = item.fileName
        statusLabel.stringValue = item.statusText
        if let fraction = item.fractionComplete {
            progress.isIndeterminate = false
            progress.doubleValue = fraction
            progress.stopAnimation(nil)
        } else if item.state == .inProgress {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        } else {
            progress.isIndeterminate = false
            progress.doubleValue = 0
            progress.stopAnimation(nil)
        }
        progress.isHidden = item.state.isFinal
        pauseButton.title = item.canResume ? "Resume" : "Pause"
        pauseButton.isHidden = !(item.canPause || item.canResume)
        cancelButton.title = item.canRemove ? "Clear" : "Cancel"
    }

    @objc private func pauseOrResume() { onPauseOrResume?() }
    @objc private func cancelOrClear() { onCancelOrClear?() }
}
