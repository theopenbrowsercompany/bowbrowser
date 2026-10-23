import AppKit
import BowCore

/// One Little Arc window: a small floating panel showing one page from a link another app sent, with a compact
/// toolbar (the page's host, a move menu and Open in Bow). Its page moves into a Space of the browser window with
/// Open in Bow (Cmd+O, the Space on screen) or with the move menu (Ctrl+1 to Ctrl+9 for the Space with that number),
/// keeping the live page: the window adopts the same engine tab and shows it, and nothing reloads. Closing Little Arc
/// closes its page, so nothing is left behind.
///
/// The panel closes when its page closes: the person closes it (the page's leave prompt is asked first, and staying
/// keeps it), the page closes itself, or Bow quits. A page that moved leaves the panel, which then goes without
/// closing it.
@MainActor
final class LittleArcPanel: NSObject, NSWindowDelegate, EngineTabDelegate, NSMenuDelegate {
    /// The page, until it moves into a Space.
    private(set) var tab: (any EngineTab)?
    let window: LittleArcWindow
    let toolbar: LittleArcToolbar
    private let webView: BowWebView
    /// The address the link opened, saved with the page when it moves before reporting its own.
    private let linkURL: URL
    /// The browser window a move goes to, looked up at the moment of the move.
    private let browserWindow: () -> BrowserWindowController?
    /// Whether the panel and the window a page moves into come forward and take the keyboard (false in e2e runs).
    private let takesFocus: Bool
    private var onClosed: ((LittleArcPanel) -> Void)?
    /// True while a close of the page is under way: a move waits until the page has answered.
    private var isClosing = false
    /// True once the panel must go whatever the page answers.
    private var forced = false
    #if BOW_E2E
        /// Told about each event of the panel's page while it is in the panel.
        var e2eTabEvent: ((any EngineTab, TabEvent) -> Void)?  // E2E seam
    #endif

    init(
        tab: any EngineTab,
        url: URL,
        frame: NSRect,
        takesFocus: Bool,
        browserWindow: @escaping () -> BrowserWindowController?,
        onClosed: @escaping (LittleArcPanel) -> Void
    ) {
        self.tab = tab
        linkURL = url
        self.browserWindow = browserWindow
        self.takesFocus = takesFocus
        self.onClosed = onClosed
        window = LittleArcWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.takesFocus = takesFocus
        toolbar = LittleArcToolbar()
        webView = BowWebView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.keyHandler = self
        window.title = url.host ?? ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        // Floats over other windows, and opens on the macOS Space the person is on, also over a full screen app.
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentMinSize = LittleArc.minimumSize

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(toolbar)
        content.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: LittleArcToolbar.height),
            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setFrame(frame, display: false)

        toolbar.host.stringValue = url.host ?? url.absoluteString
        toolbar.openButton.target = self
        toolbar.openButton.action = #selector(openInBow(_:))
        toolbar.moveButton.menu?.delegate = self
        rebuildMoveMenu()

        tab.delegate = self
        webView.show(tab)
    }

    /// Shows the panel: in front, with the keyboard in its page, when it takes focus; else ordered in without
    /// becoming key (an e2e run, whose windows stay off every screen).
    func show() {
        if takesFocus {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            webView.focusAttachedTab()
        } else {
            window.orderFrontRegardless()
        }
    }

    // MARK: Moving the page into a Space

    /// The Spaces of the browser window the page can move into, as its move menu lists them; empty with no browser
    /// window, or once the page has moved or closed.
    var moveTargets: [LittleArc.MoveTarget] {
        guard let tab, !tab.isClosed, let controller = browserWindow(), !controller.isClosing else { return [] }
        return LittleArc.moveTargets(
            in: controller.store.graph, profileID: SidebarStores.sidebarProfileID(of: tab.profileID))
    }

    /// Open in Bow (Cmd+O, the toolbar's button): moves the page into the Space the browser window shows.
    @objc func openInBow(_ sender: Any?) {
        guard let target = LittleArc.openTarget(in: moveTargets) else { return NSSound.beep() }
        move(to: target.spaceID)
    }

    /// A Space item of the move menu (Ctrl and the Space's number): moves the page into that Space.
    @objc func moveToSpace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let target = moveTargets.first(where: { $0.spaceID.rawValue == id && $0.isEnabled })
        else { return NSSound.beep() }
        move(to: target.spaceID)
    }

    /// Moves the live page into Space `spaceID` of the browser window, showing that Space and selecting the page
    /// there, then closes the panel without closing the page. Returns false, changing nothing, while a close is under
    /// way (the page's leave prompt is up), once the page has moved or closed, or when the window cannot take it.
    @discardableResult
    func move(to spaceID: SidebarSpaceID) -> Bool {
        guard !isClosing, let tab, !tab.isClosed, let controller = browserWindow(), !controller.isClosing,
            moveTargets.contains(where: { $0.spaceID == spaceID && $0.isEnabled })
        else { return false }
        if controller.store.graph.activeSpaceID != spaceID {
            guard controller.changeSidebar({ try $0.switchToSpace(spaceID) }) else { return false }
        }
        // The window takes the same engine tab and shows it in its own web view: the page keeps running as it was.
        guard controller.adoptTab(tab, after: nil, select: true, url: tab.state.url ?? linkURL) else { return false }
        self.tab = nil
        finish()
        if takesFocus {
            controller.window?.deminiaturize(nil)
            controller.showWindow(nil)
            controller.webView.focusAttachedTab()
        }
        return true
    }

    // MARK: Closing

    /// Closes the page, running its beforeunload handler once (a close already under way is not asked again); the
    /// panel goes once the page has closed. With `force` the panel leaves the screen at once, and a page that stays is
    /// unloaded, never kept unseen.
    func close(force: Bool = false) {
        guard let tab, !tab.isClosed else { return finish() }
        if force {
            forced = true
            removeWindow()
        }
        guard !isClosing else { return }
        isClosing = true
        Task { [weak self] in
            let closed = await tab.close()
            guard !closed else { return }
            self?.isClosing = false
            if self?.forced ?? true { _ = await tab.unload() }
        }
    }

    /// Takes the panel off the screen and lets go of it, once its page has closed or moved.
    private func finish() {
        removeWindow()
        onClosed?(self)
        onClosed = nil
    }

    private func removeWindow() {
        // A page that moved is shown by its new window now, so the panel's view no longer holds it; a page still
        // here is parked out of every window, which hides it.
        webView.detach()
        guard window.isVisible || window.delegate != nil else { return }
        window.delegate = nil
        window.keyHandler = nil
        window.close()
    }

    // MARK: Keys

    /// The keys of the move menu, before the page or the menu bar sees them: Cmd+O and Ctrl+1 to Ctrl+9.
    func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let menu = toolbar.moveButton.menu else { return false }
        rebuildMoveMenu()
        return menu.performKeyEquivalent(with: event)
    }

    /// The move menu: Open in Bow, then every Space of the browser window with its Ctrl number; a Space of another
    /// profile is listed but disabled. The pull-down's first item is its button's face.
    private func rebuildMoveMenu() {
        guard let menu = toolbar.moveButton.menu else { return }
        menu.removeAllItems()
        let face = NSMenuItem(title: "Move", action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Move to Space")
        menu.addItem(face)
        let targets = moveTargets
        let open = NSMenuItem(title: "Open in Bow", action: #selector(openInBow(_:)), keyEquivalent: "o")
        open.keyEquivalentModifierMask = .command
        open.target = self
        open.isEnabled = LittleArc.openTarget(in: targets) != nil
        menu.addItem(open)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for target in targets {
            let item = NSMenuItem(
                title: target.title, action: #selector(moveToSpace(_:)),
                keyEquivalent: target.shortcutNumber.map(String.init) ?? "")
            item.keyEquivalentModifierMask = .control
            item.target = self
            item.representedObject = target.spaceID.rawValue
            item.isEnabled = target.isEnabled
            item.state = target.isOnScreen ? .on : .off
            menu.addItem(item)
        }
        toolbar.openButton.isEnabled = open.isEnabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMoveMenu()
    }

    // MARK: NSWindowDelegate

    /// The browser window may have switched Spaces or closed meanwhile: Open in Bow follows.
    func windowDidBecomeKey(_ notification: Notification) {
        rebuildMoveMenu()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The close button and Close Window ask the page first; the panel follows once it has closed.
        close()
        return false
    }

    /// Close Tab (Cmd+W) in Little Arc closes it, as it would close a tab.
    @objc func closeActiveTab(_ sender: Any?) {
        close()
    }

    // MARK: EngineTabDelegate

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        #if BOW_E2E
            e2eTabEvent?(tab, event)  // E2E seam
        #endif
        switch event {
        case .stateChanged(let state):
            let host = state.url?.host ?? linkURL.host ?? ""
            toolbar.host.stringValue = host
            toolbar.host.toolTip = state.title.isEmpty ? state.url?.absoluteString : state.title
            window.title = state.title.isEmpty ? host : state.title
        case .closed, .unloaded:
            finish()
        default:
            break
        }
    }
}

/// Little Arc's window: a floating panel that stays where it is put (an e2e window off every screen too), takes its
/// keys before its page does, and closes without the alert sound while its page decides, as `BrowserWindow` does.
final class LittleArcWindow: NSPanel {
    /// False in e2e runs: the window never takes the keyboard.
    var takesFocus = true
    weak var keyHandler: LittleArcPanel?

    override var canBecomeKey: Bool { takesFocus }
    /// The browser window stays the main window, so menu commands Little Arc does not handle still reach it.
    override var canBecomeMain: Bool { false }

    override var isRestorable: Bool {
        get { false }
        set {}
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) ?? true {
            close()
        }
    }
}

/// Little Arc's compact toolbar: the page's host, then the move menu and Open in Bow at the trailing edge. It sits in
/// the title bar's strip, right of the window buttons.
final class LittleArcToolbar: NSView {
    static let height: CGFloat = 36
    /// Room for the window's close and zoom buttons at the leading edge.
    private static let leadingInset: CGFloat = 76

    let host = NSTextField(labelWithString: "")
    let moveButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let openButton = NSButton(title: "Open in Bow", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        host.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        host.textColor = .secondaryLabelColor
        host.lineBreakMode = .byTruncatingMiddle
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        host.setAccessibilityLabel("Page address")

        moveButton.bezelStyle = .accessoryBarAction
        moveButton.isBordered = false
        moveButton.controlSize = .small
        moveButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        moveButton.menu?.autoenablesItems = false
        moveButton.toolTip = "Move to Space"
        moveButton.setAccessibilityLabel("Move to Space")

        openButton.bezelStyle = .accessoryBarAction
        openButton.controlSize = .small
        openButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        openButton.image = NSImage(
            systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        openButton.imagePosition = .imageLeading
        openButton.toolTip = "Open in Bow (⌘O)"

        for view in [host, moveButton, openButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
            moveButton.leadingAnchor.constraint(greaterThanOrEqualTo: host.trailingAnchor, constant: 8),
            moveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.leadingAnchor.constraint(equalTo: moveButton.trailingAnchor, constant: 4),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
