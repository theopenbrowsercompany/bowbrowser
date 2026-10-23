import AppKit
import BowCore

/// Peek (spec/peek.md): a link previewed in a card over the page instead of a tab, as Arc does. A Shift-click opens
/// one (`PopupsFeature` answers it `.peek` through `PopupPolicy`, and the engine hands over the new page), and so does a
/// link from a pinned tab or a Favorite that leaves its site (`decideNavigation` cancels it and opens the address in a
/// new page in the same profile); `PeekPolicy` decides both. The Peek's page is a second browser in the source tab's
/// profile, shown in `PeekOverlayView` over the panes through the window's page overlay seam.
///
/// Escape, Close and a press on the dimmed page dismiss it, asking the page's leave prompt first (Stay keeps it open).
/// Open as Tab moves the same page into a tab right after its source (`adoptTab`), which reparents the browser view, so
/// nothing reloads. The Peek belongs to the sidebar item it was opened from: that tab closing, unloading or being
/// archived, another tab or Space showing, and the app quitting take it away whatever its page answers (a page that
/// stays at its leave prompt then becomes a background tab, so nothing runs unseen). Closing the window asks the Peek's
/// page first and waits (`closeBeforeWindow`): Stay keeps the window and the Peek open, Leave lets the window close.
///
/// While a Peek is open its page's alerts, confirms and prompts show as sheets on the window (`PageDialogSheets`), its key presses go
/// to the window's features (Escape closes the Peek, the other app shortcuts keep working), a sign in popup it opens
/// goes to the popup panel, and any other page it opens becomes a tab of the window.
@MainActor
final class PeekFeature: NSResponder, BrowserWindowFeature {
    private weak var window: BrowserWindowController?
    /// The Peek on screen.
    private(set) var peek: Peek?
    /// An off-site link cancelled in a tab and not yet opened (on the next main thread task), in a Peek or a new tab: a
    /// second ask about it opens nothing more, and a pending Peek counts as open.
    private var pending: (id: Int, tab: TabID, url: URL, peek: Bool)?
    private var lastPendingID = 0
    /// Peeks taken off the screen whose page has not closed yet, kept until it has.
    private var closing: [Peek] = []
    private var observers: [NSObjectProtocol] = []

    /// What the policy needs to know: the settings, read at each click, and whether a Peek is open.
    var context: PeekContext {
        PeekContext(settings: AppSettings.peekSettings, isOpen: peek != nil || pending?.peek == true)
    }

    /// The context for a navigation of `tab`: also the link it already handed over, if any.
    private func context(for tab: any EngineTab) -> PeekContext {
        var context = self.context
        if let pending, pending.tab == tab.tabID {
            context.handledURL = pending.url
        } else if let peek, peek.source === tab {
            context.handledURL = peek.url
        }
        return context
    }

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        let center = NotificationCenter.default
        if let nsWindow = window.window {
            observers.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: nsWindow, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.close(.windowClosing) }
                })
        }
        observers.append(
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.close(.windowClosing) }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Opening

    func didOpenPopup(_ newTab: any EngineTab, from tab: any EngineTab, request: PopupRequest) -> Bool {
        guard let window, !newTab.isClosed, peek == nil,
            PopupPolicy.outcome(for: request, openerZone: Self.zone(of: tab, in: window), peek: context).decision
                == .peek
        else { return false }
        return open(newTab, source: tab, url: request.targetURL)
    }

    func decideNavigation(_ navigation: EngineNavigation, for tab: any EngineTab) -> NavigationPolicy? {
        guard let window, !window.isClosing else { return nil }
        let zone = Self.zone(of: tab, in: window)
        let outcome = PeekPolicy.navigationOutcome(
            navigation, currentURL: tab.state.url, openerZone: zone, context: context(for: tab))
        switch outcome {
        case .navigate: return nil
        case .alreadyHandled: return .cancel
        case .peek, .newTab: break
        }
        guard let profile = window.engineProfile(of: tab) else { return nil }
        let url = navigation.url
        lastPendingID += 1
        let id = lastPendingID
        pending = (id, tab.tabID, url, outcome == .peek)
        // The engine asks from inside its navigation callback, so the new page is created on the next turn.
        Task { @MainActor [weak self, weak tab] in
            guard let self, self.pending?.id == id else { return }
            self.pending = nil
            guard let window = self.window, let tab, !tab.isClosed, window.modelID(of: tab) != nil,
                !window.isClosing
            else { return }
            let page = profile.createTab(url: url)
            if outcome == .peek, self.peek == nil, self.open(page, source: tab, url: url) { return }
            // With the setting off (or a Peek already open) the link opens as a new tab where the source's new pages go.
            if !window.adoptTab(
                page, after: tab, placement: PeekPolicy.promotedPlacement(openerZone: zone), select: true, url: url)
            {
                _ = await page.close()
            }
        }
        return .cancel
    }

    /// Shows `page` in a Peek owned by `source`, one of the window's tabs. Returns false, showing nothing, when the
    /// window cannot take it.
    private func open(_ page: any EngineTab, source: any EngineTab, url: URL?) -> Bool {
        guard let window, !window.isClosing, peek == nil, let sourceID = window.modelID(of: source),
            let item = window.sidebarItemID(for: sourceID)
        else { return false }
        let overlay = PeekOverlayView(frame: window.pageArea.bounds)
        let peek = Peek(page: page, source: source, sourceItem: item, url: url, overlay: overlay, feature: self)
        overlay.onDismiss = { [weak self, weak peek] in
            guard let self, let peek, self.peek === peek else { return }
            self.close(.dismissed)
        }
        overlay.onPromote = { [weak self, weak peek] in
            guard let self, let peek, self.peek === peek else { return }
            self.promote()
        }
        self.peek = peek
        window.addPageOverlay(overlay)
        overlay.layoutSubtreeIfNeeded()
        overlay.webView.show(page)
        if window.window?.isKeyWindow == true { overlay.webView.focusAttachedTab() }
        return true
    }

    // MARK: Closing and promoting

    /// Takes the Peek away for `cause`. A dismissed Peek asks its page first and stays open when the person stays;
    /// any other cause takes it off the screen at once (`PeekPolicy.pageMayStay`).
    func close(_ cause: PeekCloseCause) {
        if pending?.peek == true { pending = nil }
        guard let peek else { return }
        let page = peek.page
        if PeekPolicy.pageMayStay(cause) {
            _ = askToClose(peek)
            return
        }
        takeOffScreen(peek)
        closing.append(peek)
        Task { [weak self] in
            guard !(await page.close()) else { return }
            // The person stayed on the page at its leave prompt: it becomes a tab in the background rather than
            // running unseen, or, with no window to take it, is unloaded.
            if let self, let window = self.window, !page.isClosed,
                window.adoptTab(
                    page, after: peek.source, placement: PeekPolicy.promotedPlacement(openerZone: peek.zone),
                    select: false, url: page.state.url ?? peek.url)
            {
                self.closing.removeAll { $0 === peek }
                return
            }
            _ = await page.unload()
        }
    }

    /// Asks the Peek's page to close, running its leave prompt, and returns whether it closed. A close already waiting
    /// for the person's answer is shared, so a second dismiss or a window close asks once. Once the page has closed the
    /// card leaves the screen; when the person stays, the Peek stays as it was.
    private func askToClose(_ peek: Peek) -> Task<Bool, Never> {
        if let task = peek.closeTask { return task }
        let page = peek.page
        let task = Task { [weak self, weak peek] in
            let closed = await page.close()
            peek?.closeTask = nil
            if closed, let self, let peek { self.pageDidClose(peek) }
            return closed
        }
        peek.closeTask = task
        return task
    }

    /// The window is closing: the Peek's page answers first, and the window closes its tabs only once it has left
    /// (Stay keeps the window and the Peek open). With no Peek there is nothing to ask.
    func closeBeforeWindow() -> Task<Bool, Never>? {
        if pending?.peek == true { pending = nil }
        guard let peek, !peek.page.isClosed else { return nil }
        return askToClose(peek)
    }

    /// Open as Tab: the Peek's page becomes a tab right after its source (at the top of Today for a pinned tab or a
    /// Favorite), shown at once, with the same browser moved into the page area, so nothing reloads.
    func promote() {
        guard let window, let peek, !peek.page.isClosed else { return }
        self.peek = nil
        let adopted = window.adoptTab(
            peek.page, after: peek.source, placement: PeekPolicy.promotedPlacement(openerZone: peek.zone),
            select: true, url: peek.page.state.url ?? peek.url)
        guard adopted else {
            self.peek = peek
            return
        }
        // The window shows the page now, and its page dialogs are the window's; only the empty card goes.
        peek.dialogs.close()
        peek.overlay.onDismiss = nil
        peek.overlay.onPromote = nil
        peek.overlay.removeFromSuperview()
        peek.isPromoted = true
    }

    private func takeOffScreen(_ peek: Peek) {
        if self.peek === peek { self.peek = nil }
        peek.overlay.onDismiss = nil
        peek.overlay.onPromote = nil
        peek.overlay.webView.detach()
        peek.overlay.removeFromSuperview()
        peek.dialogs.close()
        window.map { popupPanels(of: $0)?.tabDidClose(peek.page) }
    }

    /// The Peek's page closed (its page called `window.close()`, a dismiss went through, quitting).
    fileprivate func pageDidClose(_ peek: Peek) {
        if self.peek === peek { takeOffScreen(peek) }
        closing.removeAll { $0 === peek }
    }

    // MARK: The source

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        guard let peek else { return }
        guard let tab, tab === peek.source else { return close(.sourceHidden) }
    }

    func activeSpaceChanged(_ space: SidebarSpace) {
        // Another Space on screen hides the source, as in Arc.
        close(.sourceHidden)
    }

    func tabDidClose(_ tab: any EngineTab) {
        // Closing, unloading or the window closing the source all end here.
        if let peek, tab === peek.source { close(.sourceGone) }
    }

    func storeChanged(_ graph: SidebarGraph) {
        // Archived or deleted from the sidebar: the item has gone before its page closes.
        if let peek, graph[peek.sourceItem] == nil { close(.sourceGone) }
    }

    // MARK: Keys

    func handleKeyBeforePage(_ event: EngineKeyEvent, in tab: any EngineTab) -> Bool {
        guard peek != nil, KeyShortcuts.shortcut(for: event, claimedBy: .peek) == .closeCommandBar else {
            return false
        }
        close(.dismissed)
        return true
    }

    /// Escape while the keyboard is in the window's own views (the sidebar, for example).
    override func cancelOperation(_ sender: Any?) {
        guard peek != nil else { return super.cancelOperation(sender) }
        close(.dismissed)
    }

    // MARK: Helpers

    fileprivate func popupPanels(of window: BrowserWindowController) -> PopupPanelFeature? {
        window.feature(PopupPanelFeature.self)
    }

    fileprivate var controller: BrowserWindowController? { window }

    /// Where `tab`, one of `window`'s tabs, sits in the sidebar.
    static func zone(of tab: any EngineTab, in window: BrowserWindowController) -> PopupOpenerZone {
        guard let item = window.modelID(of: tab).flatMap({ window.sidebarItemID(for: $0) }) else { return .today }
        let graph = window.store.graph
        if graph.isInFavorites(item) { return .favorite }
        if graph.isPinned(item) { return .pinned }
        return .today
    }
}

/// One Peek: its page, the tab and sidebar item it belongs to, its card, and the page's delegate while it is a Peek.
@MainActor
final class Peek: NSObject, EngineTabDelegate {
    let page: any EngineTab
    /// The tab the Peek was opened from. Weak: the window owns it.
    private(set) weak var source: (any EngineTab)?
    let sourceItem: SidebarItemID
    /// Where the source sat when the Peek opened, which decides where a promoted Peek goes.
    var zone: PopupOpenerZone
    /// The address the Peek opened, until its page reports its own.
    let url: URL?
    let overlay: PeekOverlayView
    private weak var feature: PeekFeature?
    /// The page's close while it waits for the leave prompt's answer (a dismiss or the window closing).
    var closeTask: Task<Bool, Never>?
    /// True once the page became a tab; the window is its delegate from then on.
    var isPromoted = false
    /// The page's alerts, confirms and prompts, as sheets on the browser window while the Peek shows (the same rules
    /// and sheet as a tab's). Closed when the Peek leaves the screen or becomes a tab.
    let dialogs: PageDialogSheets

    init(
        page: any EngineTab, source: any EngineTab, sourceItem: SidebarItemID, url: URL?, overlay: PeekOverlayView,
        feature: PeekFeature
    ) {
        self.page = page
        self.source = source
        self.sourceItem = sourceItem
        self.url = url
        self.overlay = overlay
        self.feature = feature
        zone = feature.controller.map { PeekFeature.zone(of: source, in: $0) } ?? .today
        dialogs = PageDialogSheets(window: feature.controller?.window, shownTab: page.tabID)
        super.init()
        page.delegate = self
    }

    private var window: BrowserWindowController? { feature?.controller }

    // MARK: EngineTabDelegate

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        switch event {
        case .didStartNavigation, .renderProcessGone:
            dialogs.navigated(tab.tabID)
        default:
            break
        }
        // The window's tab event observer hears the Peek's page as it hears its tabs (e2e runs follow its loads).
        window?.onTabEvent?(tab, event)
        if event == .closed || event == .unloaded { feature?.pageDidClose(self) }
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy {
        window?.navigationPolicy?(tab, navigation) ?? .allow
    }

    func tab(_ tab: any EngineTab, decidePopup request: PopupRequest) -> PopupDecision {
        guard let window, !window.isClosing else { return .block }
        return PeekPolicy.decisionInPeek(for: request)
    }

    func tab(_ tab: any EngineTab, didOpenPopup newTab: any EngineTab, request: PopupRequest) {
        if let window, !window.isClosing {
            switch PeekPolicy.decisionInPeek(for: request) {
            case .popupPanel:
                if feature?.popupPanels(of: window)?.didOpenPopup(newTab, from: tab, request: request) == true {
                    return
                }
            case .foregroundTab, .backgroundTab:
                let select = PeekPolicy.decisionInPeek(for: request) == .foregroundTab
                if window.adoptTab(
                    newTab, after: source, placement: PeekPolicy.promotedPlacement(openerZone: zone), select: select,
                    url: request.targetURL)
                {
                    return
                }
            case .peek, .window, .block:
                break
            }
        }
        Task { _ = await newTab.close() }
    }

    func tab(_ tab: any EngineTab, handleKeyBeforePage event: EngineKeyEvent) -> Bool {
        guard let window else { return false }
        return window.features.contains { $0.handleKeyBeforePage(event, in: tab) }
    }

    func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer {
        await dialogs.run(dialog, for: tab.tabID)
    }
}
