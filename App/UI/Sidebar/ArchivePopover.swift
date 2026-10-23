import AppKit
import BowCore

/// The content of the archive popover (spec/auto-archive.md): the profile's archived tabs newest first, each with its
/// site icon, title, source Space and when it was archived, a click on one puts it back (`ArchiveCenter.reopen`),
/// and at the bottom the profile's "Archive tabs after" menu. Built each time the popover opens, so it shows the
/// archive as it is then.
@MainActor
final class ArchivePopoverController: NSViewController {
    static let width: CGFloat = 320
    static let maxListHeight: CGFloat = 280
    static let rowHeight: CGFloat = 44
    static let rowIdentifierPrefix = "archive-row-"
    static let thresholdIdentifier = "archive-threshold"
    static let emptyIdentifier = "archive-empty"

    private let center: ArchiveCenter
    private weak var window: BrowserWindowController?
    /// Asked to close the popover once an item is back.
    var close: (() -> Void)?
    private let profile: SidebarProfileID?
    private(set) var rows: [ArchiveRowButton] = []
    private(set) var thresholdButton: NSPopUpButton?

    init(center: ArchiveCenter, window: BrowserWindowController) {
        self.center = center
        self.window = window
        self.profile = window.store.graph.activeSpace?.profileID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let entries = window.map { center.entries(in: $0.store, profile: profile) } ?? []
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let header = NSTextField(labelWithString: "Archived Tabs")
        header.font = BowBrand.ui(weight: .bold)
        header.textColor = BowBrand.text
        content.addArrangedSubview(header)

        let inner = Self.width - 28
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No archived tabs")
            empty.font = BowBrand.ui()
            empty.textColor = BowBrand.soft
            empty.identifier = NSUserInterfaceItemIdentifier(Self.emptyIdentifier)
            content.addArrangedSubview(empty)
        } else {
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 2
            list.translatesAutoresizingMaskIntoConstraints = false
            let graph = window?.store.graph
            rows = entries.map { entry in
                let space = graph?.space(SidebarSpaceID(rawValue: entry.source.spaceID))
                let row = ArchiveRowButton(
                    entry: entry, spaceName: space.map { SpaceNameView.title(of: $0) },
                    archivedAgo: Self.ago(entry.archivedAt, now: center.clock.now))
                row.target = self
                row.action = #selector(reopen(_:))
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: inner).isActive = true
                return row
            }
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = list
            let height = min(CGFloat(entries.count) * (Self.rowHeight + 2), Self.maxListHeight)
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalToConstant: inner),
                scroll.heightAnchor.constraint(equalToConstant: height),
                list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                list.widthAnchor.constraint(equalToConstant: inner),
            ])
            content.addArrangedSubview(scroll)
        }

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = BowBrand.line
        divider.widthAnchor.constraint(equalToConstant: inner).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        content.addArrangedSubview(divider)

        let label = NSTextField(labelWithString: "Archive tabs after:")
        label.font = BowBrand.ui()
        label.textColor = BowBrand.text
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.font = BowBrand.ui()
        for threshold in AutoArchiveThreshold.allCases {
            menu.addItem(withTitle: threshold.title)
            menu.lastItem?.representedObject = threshold.rawValue
        }
        let current = profile.map { center.threshold(for: $0) } ?? .default
        menu.selectItem(at: AutoArchiveThreshold.allCases.firstIndex(of: current) ?? 0)
        // With no Space on screen there is no profile to save for.
        menu.isEnabled = profile != nil
        menu.target = self
        menu.action = #selector(thresholdChanged(_:))
        menu.identifier = NSUserInterfaceItemIdentifier(Self.thresholdIdentifier)
        menu.setAccessibilityLabel("Archive tabs after")
        thresholdButton = menu
        let footer = NSStackView(views: [label, menu])
        footer.orientation = .horizontal
        footer.spacing = 8
        content.addArrangedSubview(footer)

        content.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = content
    }

    @objc private func reopen(_ sender: ArchiveRowButton) {
        guard let window else { return }
        // A row that cannot be put back (reopened in another window meanwhile) stays up to date on the next open.
        if center.reopen(sender.entryID, in: window) { close?() } else { NSSound.beep() }
    }

    @objc private func thresholdChanged(_ sender: NSPopUpButton) {
        guard let profile, let raw = sender.selectedItem?.representedObject as? String,
            let threshold = AutoArchiveThreshold(rawValue: raw)
        else { return }
        center.setThreshold(threshold, for: profile)
    }

    /// "3 hours ago", "yesterday": when an item was archived, against the archive clock.
    static func ago(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// One archived item in the list: a borderless button showing its icon, title and where and when it was archived.
@MainActor
final class ArchiveRowButton: NSButton {
    let entryID: SidebarItemID
    let titleText: String
    let detailText: String
    private let titleField: NSTextField
    private let detailField: NSTextField

    init(entry: ArchivedEntry, spaceName: String?, archivedAgo: String) {
        entryID = entry.id
        if let saved = entry.item.tab {
            titleText = FavoritesGridView.title(of: entry.item, saved: saved)
        } else {
            titleText = entry.item.title ?? "Untitled"
        }
        detailText = [spaceName, archivedAgo].compactMap { $0 }.joined(separator: " · ")
        titleField = NSTextField(labelWithString: titleText)
        detailField = NSTextField(labelWithString: detailText)
        super.init(frame: .zero)
        isBordered = false
        title = ""
        identifier = NSUserInterfaceItemIdentifier(ArchivePopoverController.rowIdentifierPrefix + entry.id.rawValue)
        setAccessibilityLabel("\(titleText), \(detailText)")
        toolTip = entry.savedURL
        wantsLayer = true
        layer?.cornerRadius = BowBrand.radiusRow

        let icon = NSImageView(
            image: NSImage(systemSymbolName: entry.item.tab != nil ? "globe" : "folder", accessibilityDescription: nil)
                ?? NSImage())
        icon.contentTintColor = BowBrand.soft
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        titleField.font = BowBrand.ui()
        titleField.textColor = BowBrand.text
        titleField.lineBreakMode = .byTruncatingTail
        detailField.font = BowBrand.ui(11.5)
        detailField.textColor = BowBrand.soft
        detailField.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [titleField, detailField])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: ArchivePopoverController.rowHeight),
        ])
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The labels inside take no clicks: the whole row is the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = BowBrand.pin.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
