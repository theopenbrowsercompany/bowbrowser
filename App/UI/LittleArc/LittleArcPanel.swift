import AppKit
import BowCore

/// One Little Arc window: a small floating panel showing one page from a link another app sent, with a compact
/// toolbar (the page's address, a move menu and Open in Bow). Its page moves into a Space of the browser window with
/// Open in Bow (Cmd+O, the Space on screen) or with the move menu (Ctrl+1 to Ctrl+9 for the Space with that number),
/// keeping the live page: the window adopts the same engine tab and shows it, and nothing reloads. With no browser
/// window open, Open in Bow opens one on a Space of the page's profile and moves the page there. Closing Little Arc
/// closes its page, so nothing is left behind.
///
/// The page's alerts, confirms and prompts come up as sheets on the panel (`PageDialogSheets`), and its permission
/// requests as the browser window's prompt, anchored to the panel's page (`PermissionPrompts`). While Little Arc is
/// key, the page commands of the main menu (reload, stop, back, forward, Open Location) act on its page, and find is
/// disabled, so none reaches the browser window behind it.
///
/// The panel closes when its page closes: the person closes it (the page's leave prompt is asked first, and staying
/// keeps it), the page closes itself, or Bow quits. A page that moved leaves the panel, which then goes without
/// closing it.
@MainActor
final class LittleArcPanel: NSObject, NSWindowDelegate, EngineTabDelegate, NSMenuDelegate, NSMenuItemValidation,
    NSTextFieldDelegate
{
    /// The page, until it moves into a Space.
    private(set) var tab: (any EngineTab)?
    let window: LittleArcWindow
    let toolbar: LittleArcToolbar
    private let webView: BowWebView
    /// The page's alert, confirm and prompt, as sheets on the panel under the same rules as a tab's.
    let dialogs: PageDialogSheets
    /// The page's permission requests: remembered answers of its profile, or the prompt anchored to the page.
    let prompts: PermissionPrompts
    /// The address the link opened, saved with the page when it moves before reporting its own.
    private let linkURL: URL
    /// The browser window a move goes to, looked up at the moment of the move.
    private let browserWindow: () -> BrowserWindowController?
    /// Opens a browser window showing a Space of the given profile, for Open in Bow with no browser window open; nil
    /// when none can open.
    private let openWindow: (SidebarProfileID) -> BrowserWindowController?
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
        /// Makes the next move's adopt fail after the Space switch, as a window refusing the page would.
        var e2eFailsAdopt = false  // E2E seam
    #endif

    init(
        tab: any EngineTab,
        url: URL,
        frame: NSRect,
        takesFocus: Bool,
        permissions: PermissionPrompts.ProfilePermissions?,
        browserWindow: @escaping () -> BrowserWindowController?,
        openWindow: @escaping (SidebarProfileID) -> BrowserWindowController?,
        onClosed: @escaping (LittleArcPanel) -> Void
    ) {
        self.tab = tab
        linkURL = url
        self.browserWindow = browserWindow
        self.openWindow = openWindow
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
        dialogs = PageDialogSheets(window: window, shownTab: tab.tabID)
        // A page whose profile has no permission store has its requests dismissed, as in a browser window.
        prompts = PermissionPrompts(hostView: webView) { _ in permissions }
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
        toolbar.host.delegate = self
        toolbar.openButton.target = self
        toolbar.openButton.action = #selector(openInBow(_:))
        toolbar.moveButton.menu?.delegate = self
        rebuildMoveMenu()

        tab.delegate = self
        webView.show(tab)
        prompts.show(tab)
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
        guard let tab, !tab.isClosed, let controller = liveBrowserWindow() else { return [] }
        return LittleArc.moveTargets(
            in: controller.store.graph, profileID: SidebarStores.sidebarProfileID(of: tab.profileID))
    }

    /// The browser window a move goes to, unless it is closing.
    private func liveBrowserWindow() -> BrowserWindowController? {
        browserWindow().flatMap { $0.isClosing ? nil : $0 }
    }

    /// Open in Bow (Cmd+O, the toolbar's button): moves the page into the Space the browser window shows. With no
    /// browser window open, a new one opens on a Space of the page's profile (the Space shown last when it has that
    /// profile) and the page moves there.
    @objc func openInBow(_ sender: Any?) {
        guard let tab, !tab.isClosed, !isClosing, !dialogs.hasDialog(for: tab.tabID) else { return NSSound.beep() }
        let controller: BrowserWindowController
        if let open = liveBrowserWindow() {
            controller = open
        } else {
            guard let opened = openWindow(SidebarStores.sidebarProfileID(of: tab.profileID)) else {
                return NSSound.beep()
            }
            controller = opened
        }
        let targets = LittleArc.moveTargets(
            in: controller.store.graph, profileID: SidebarStores.sidebarProfileID(of: tab.profileID))
        guard let target = LittleArc.openTarget(in: targets), move(to: target.spaceID, in: controller) else {
            return NSSound.beep()
        }
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
    /// way (the page's leave prompt is up), while a page dialog is up, once the page has moved or closed, or when the
    /// window cannot take it; a window that switched Space for the move and then refused the page switches back.
    @discardableResult
    func move(to spaceID: SidebarSpaceID) -> Bool {
        guard let controller = liveBrowserWindow() else { return false }
        return move(to: spaceID, in: controller)
    }

    private func move(to spaceID: SidebarSpaceID, in controller: BrowserWindowController) -> Bool {
        guard !isClosing, let tab, !tab.isClosed, !controller.isClosing, !dialogs.hasDialog(for: tab.tabID) else {
            return false
        }
        let targets = LittleArc.moveTargets(
            in: controller.store.graph, profileID: SidebarStores.sidebarProfileID(of: tab.profileID))
        guard targets.contains(where: { $0.spaceID == spaceID && $0.isEnabled }) else { return false }
        let previousSpace = controller.store.graph.activeSpaceID
        if previousSpace != spaceID {
            guard controller.changeSidebar({ try $0.switchToSpace(spaceID) }) else { return false }
        }
        // The window takes the same engine tab and shows it in its own web view: the page keeps running as it was.
        var adopted = true
        #if BOW_E2E
            if e2eFailsAdopt { adopted = false }  // E2E seam
        #endif
        if adopted { adopted = controller.adoptTab(tab, after: nil, select: true, url: tab.state.url ?? linkURL) }
        guard adopted else {
            // The window goes back to the Space it showed, and the page stays here as it was.
            if let previousSpace, previousSpace != spaceID, controller.store.graph.space(previousSpace) != nil {
                controller.changeSidebar { try $0.switchToSpace(previousSpace) }
            }
            if tab.delegate !== self { tab.delegate = self }
            return false
        }
        // A permission request belongs to the panel's prompt; the page asks again in its window if it needs to.
        prompts.dismissRequests(of: tab)
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
        // A dialog up as a sheet is answered as cancelled and taken down first (AppKit refuses to close a window with
        // a sheet), and a waiting permission request is dismissed with its prompt, so the page waits on nothing.
        dialogs.close()
        if let tab { prompts.dismissRequests(of: tab) }
        // A page that moved is shown by its new window now, so the panel's view no longer holds it; a page still
        // here is parked out of every window, which hides it.
        webView.detach()
        guard window.isVisible || window.delegate != nil else { return }
        window.delegate = nil
        window.keyHandler = nil
        window.close()
    }

    // MARK: Main menu commands while Little Arc is key

    /// The page's navigation controls, `disabled` once it has moved or closed.
    private var controls: NavigationControls {
        guard let tab, !tab.isClosed else { return .disabled }
        let state = tab.state
        return NavigationControls(
            canGoBack: state.canGoBack, canGoForward: state.canGoForward, canReload: true, isLoading: state.isLoading)
    }

    /// View > Reload Page (Cmd+R): reloads Little Arc's page, never the browser window's.
    @objc func reloadPage(_ sender: Any?) {
        tab?.reload()
    }

    /// View > Stop (Cmd+.).
    @objc func stopLoading(_ sender: Any?) {
        tab?.stop()
    }

    /// History > Back (Cmd+[).
    @objc func goBack(_ sender: Any?) {
        tab?.goBack()
    }

    /// History > Forward (Cmd+]).
    @objc func goForward(_ sender: Any?) {
        tab?.goForward()
    }

    /// View > Open Location (Cmd+L): the toolbar's address becomes editable, showing the page's full address
    /// selected. Return loads what was typed (an address or a search) in Little Arc's page; Escape puts the host back.
    @objc func openLocation(_ sender: Any?) {
        guard let tab, !tab.isClosed else { return }
        let field = toolbar.host
        field.isEditable = true
        field.stringValue = tab.state.url?.absoluteString ?? linkURL.absoluteString
        guard window.makeFirstResponder(field) else { return showHost() }
        field.currentEditor()?.selectAll(nil)
    }

    /// Find (Cmd+F), Find Next and Find Previous: disabled while Little Arc is key, so they never search the browser
    /// window behind it (`LittleArc.isEnabled`).
    @objc func showFindBar(_ sender: Any?) {}
    @objc func findNext(_ sender: Any?) {}
    @objc func findPrevious(_ sender: Any?) {}

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let command: LittleArc.MenuCommand
        switch menuItem.action {
        case #selector(reloadPage(_:)): command = .reload
        case #selector(stopLoading(_:)): command = .stop
        case #selector(goBack(_:)): command = .back
        case #selector(goForward(_:)): command = .forward
        case #selector(openLocation(_:)): command = .openLocation
        case #selector(showFindBar(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)): command = .find
        default: return true
        }
        return LittleArc.isEnabled(command, controls: controls)
    }

    // MARK: The address

    /// True while the toolbar's address is being edited.
    var isEditingAddress: Bool {
        guard let editor = toolbar.host.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    /// The host the toolbar shows while the address is not being edited.
    private var host: String {
        tab?.state.url?.host ?? linkURL.host ?? linkURL.absoluteString
    }

    private func showHost() {
        toolbar.host.isEditable = false
        toolbar.host.stringValue = host
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === toolbar.host else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if let tab, !tab.isClosed, let url = AddressInput.resolve(textView.string) { tab.load(url) }
            endAddressEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endAddressEditing()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        showHost()
    }

    private func endAddressEditing() {
        window.makeFirstResponder(nil)
        showHost()
        if takesFocus { webView.focusAttachedTab() }
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
        let hasPage = tab.map { !$0.isClosed } ?? false
        open.isEnabled = hasPage && LittleArc.canOpenInBow(hasBrowserWindow: liveBrowserWindow() != nil, targets: targets)
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
            if !isEditingAddress { toolbar.host.stringValue = host }
            toolbar.host.toolTip = state.title.isEmpty ? state.url?.absoluteString : state.title
            window.title = state.title.isEmpty ? host : state.title
        case .didStartNavigation, .renderProcessGone:
            // A dialog belongs to the page it came from.
            dialogs.navigated(tab.tabID)
        case .didCommit:
            // A prompt belongs to the page that asked; a new page asks again if it needs to.
            prompts.dismissRequests(of: tab)
        case .closed, .unloaded:
            finish()
        default:
            break
        }
    }

    func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer {
        await dialogs.run(dialog, for: tab.tabID)
    }

    func tab(_ tab: any EngineTab, decidePermission request: PermissionRequest) async -> PermissionDecision {
        await prompts.decide(request, for: tab)
    }
}

/// Little Arc's window: a floating panel that stays where it is put (an e2e window off every screen too), takes its
/// keys before its page does, and closes without the alert sound while its page decides, as `BrowserWindow` does.
final class LittleArcWindow: NSPanel {
    /// False in e2e runs: the window never takes the keyboard.
    var takesFocus = true
    weak var keyHandler: LittleArcPanel?

    override var canBecomeKey: Bool { takesFocus }
    /// The browser window stays the main window. Little Arc's panel answers the page commands of the main menu
    /// itself while it is key; the window's other commands (New Tab, the sidebar's) still reach the browser window.
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

/// Little Arc's compact toolbar: the page's address (its host, editable with Open Location), then the move menu and
/// Open in Bow at the trailing edge. It sits in the title bar's strip, right of the window buttons.
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
        host.cell?.usesSingleLineMode = true
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
