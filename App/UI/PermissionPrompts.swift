import AppKit
import BowCore

/// Answers one window's permission requests: from the remembered answers of the profile the asking tab runs in when
/// it has one, otherwise by asking the person in a prompt anchored to the top of the page, then remembering their
/// answer per site in that profile's store and in the engine's content settings. Each tab uses its own profile, so a
/// window whose Spaces use different profiles keeps their answers apart.
///
/// Requests wait in order. Each tab the window shows (one per pane of a split view) shows its own first request in a
/// prompt anchored to its own pane, focused or not; a tab that leaves the screen hides its prompt until it shows
/// again, and a request whose tab closes or leaves the page is dismissed.
@MainActor
final class PermissionPrompts {
    private struct Pending {
        let id: Int
        let tab: any EngineTab
        let request: PermissionRequest
        let site: ProfilePermissions
        let answer: CheckedContinuation<PermissionDecision, Never>
    }

    /// A tab's profile and that profile's permission store.
    struct ProfilePermissions {
        let store: SitePermissionStore
        let profile: any EngineProfile
    }

    /// A tab the window shows and the view of its pane, which its prompt is anchored to.
    private struct Shown {
        weak var tab: (any EngineTab)?
        weak var view: NSView?
    }

    /// The profile and store of a tab, nil when its profile is unknown (its requests are dismissed).
    private let permissions: (any EngineTab) -> ProfilePermissions?
    private var pending: [Pending] = []
    private var lastPendingID = 0
    /// The prompts on screen by the waiting request they answer: one per shown pane whose tab has a request, showing
    /// that tab's first one.
    private var visiblePrompts: [Int: PermissionPromptPanel] = [:]
    /// The tabs the window shows, one per pane, with their panes' views.
    private var shown: [Shown] = []
    /// Follows the frames of the shown panes' views, which move when the window resizes or a divider moves.
    private var frameObservers: [NSObjectProtocol] = []
    private var storeObserver: NSObjectProtocol?

    /// Posted with a store as its object after an answer is recorded in it, so every window on the profile settles
    /// the requests the answer covers.
    private static let storeChanged = Notification.Name("BowSitePermissionStoreChanged")

    init(permissions: @escaping (any EngineTab) -> ProfilePermissions?) {
        self.permissions = permissions
        storeObserver = NotificationCenter.default.addObserver(
            forName: Self.storeChanged, object: nil, queue: .main
        ) { [weak self] notification in
            // Only the store's identity crosses into the main actor; the store itself is read there.
            guard let object = notification.object as AnyObject? else { return }
            let changed = ObjectIdentifier(object)
            MainActor.assumeIsolated { self?.settle(changed) }
        }
    }

    isolated deinit {
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        for prompt in visiblePrompts.values { prompt.close() }
    }

    /// The prompt on screen for `tab`'s first waiting request, nil when it shows none.
    func visiblePrompt(for tab: any EngineTab) -> PermissionPromptPanel? {
        visiblePrompts.values.first { prompt in pending.contains { $0.id == prompt.entryID && $0.tab === tab } }
    }

    /// The answer to `request` from `tab`: remembered, or the person's once they answer the prompt.
    func decide(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision {
        guard let site = permissions(tab) else { return .dismiss }
        if let remembered = site.store.decision(for: request) { return remembered }
        return await withCheckedContinuation { answer in
            lastPendingID += 1
            pending.append(Pending(id: lastPendingID, tab: tab, request: request, site: site, answer: answer))
            update()
        }
    }

    /// Shows the prompts of `panes`, the tabs the window now shows with their panes' views (empty when none): each
    /// tab's first waiting request, anchored to its own pane. Tabs no longer shown keep their requests waiting.
    func show(_ panes: [(tab: any EngineTab, view: NSView)]) {
        shown = panes.map { Shown(tab: $0.tab, view: $0.view) }
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        frameObservers = panes.map { pane in
            pane.view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: pane.view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.placePrompts() }
            }
        }
        update()
    }

    /// Dismisses every request of `tab`: it closed, or its page went away.
    func dismissRequests(of tab: any EngineTab) {
        let dismissed = pending.filter { $0.tab === tab }
        guard !dismissed.isEmpty else { return }
        pending.removeAll { $0.tab === tab }
        for request in dismissed { request.answer.resume(returning: .dismiss) }
        update()
    }

    /// The person answered the prompt built for the waiting request `entryID`. A prompt that was replaced in the
    /// meantime answers nothing.
    private func answer(_ decision: PermissionDecision, entryID: Int) {
        guard let index = pending.firstIndex(where: { $0.id == entryID }) else { return }
        let answered = pending.remove(at: index)
        remember(decision, for: answered.request, in: answered.site)
        answered.answer.resume(returning: decision)
        update()
        // The answer may settle other waiting requests from the same site and profile, in this window and others.
        NotificationCenter.default.post(name: Self.storeChanged, object: answered.site.store)
    }

    /// Answers every waiting request on the store `changed` that it now has an answer for.
    private func settle(_ changed: ObjectIdentifier) {
        let settled = pending.compactMap { entry in
            ObjectIdentifier(entry.site.store) == changed
                ? entry.site.store.decision(for: entry.request).map { (entry, $0) } : nil
        }
        guard !settled.isEmpty else { return }
        pending.removeAll { entry in settled.contains { $0.0.id == entry.id } }
        for (entry, decision) in settled { entry.answer.resume(returning: decision) }
        update()
    }

    private func remember(_ decision: PermissionDecision, for request: PermissionRequest, in site: ProfilePermissions) {
        let store = site.store
        let profile = site.profile
        do {
            try store.record(decision, for: request)
        } catch {
            // The store still holds the answer while the app runs; it is asked again after a restart.
            NSLog("Bow: could not save a permission answer: %@", String(describing: error))
        }
        // Read back what the store holds, so the engine agrees with it even when the file could not be written.
        guard let site = request.site else { return }
        for kind in request.kinds {
            if let setting = store.setting(for: kind, on: site) { profile.setPermission(setting, for: kind, on: site) }
        }
    }

    /// The pane view each waiting request shown now is anchored to, by request: the first request of each shown tab.
    private var wanted: [Int: NSView] {
        var result: [Int: NSView] = [:]
        for pane in shown {
            guard let tab = pane.tab, let view = pane.view, view.window != nil,
                let entry = pending.first(where: { $0.tab === tab })
            else { continue }
            result[entry.id] = view
        }
        return result
    }

    private func update() {
        let wanted = self.wanted
        for (entryID, prompt) in visiblePrompts where wanted[entryID] == nil {
            prompt.parent?.removeChildWindow(prompt)
            prompt.close()
            visiblePrompts[entryID] = nil
        }
        for (entryID, view) in wanted where visiblePrompts[entryID] == nil {
            guard let entry = pending.first(where: { $0.id == entryID }), let window = view.window else { continue }
            let prompt = PermissionPromptPanel(request: entry.request, entryID: entryID) { [weak self] decision in
                self?.answer(decision, entryID: entryID)
            }
            visiblePrompts[entryID] = prompt
            // Mission Control hides the prompt when it hides its window (as it does an e2e run's windows).
            if window.collectionBehavior.contains(.transient) { prompt.collectionBehavior.insert(.transient) }
            window.addChildWindow(prompt, ordered: .above)
        }
        placePrompts()
    }

    /// Puts each prompt at the top leading corner of its tab's pane, inset a little, as macOS browsers place theirs.
    private func placePrompts() {
        for (entryID, view) in wanted {
            guard let prompt = visiblePrompts[entryID], let window = view.window else { continue }
            let inset: CGFloat = 12
            let top = view.isFlipped ? view.bounds.minY : view.bounds.maxY
            let topLeft = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.minX, y: top), to: nil))
            let size = prompt.frame.size
            let origin = NSPoint(x: topLeft.x + inset, y: topLeft.y - inset - size.height)
            prompt.setFrame(NSRect(origin: origin, size: size), display: false)
        }
    }
}

/// The prompt itself: a small borderless panel attached to the browser window, naming the site and what it asks
/// for, with Block and Allow, and a close button that answers neither. It never activates the app or takes the keyboard from the page.
@MainActor
final class PermissionPromptPanel: NSPanel {
    let request: PermissionRequest
    /// Which waiting request this prompt answers.
    fileprivate let entryID: Int
    let message: String
    let allowButton: NSButton
    let blockButton: NSButton
    /// Closes the prompt without an answer, so nothing is granted or remembered.
    let closeButton: NSButton
    private let onAnswer: (PermissionDecision) -> Void
    private var answered = false

    fileprivate init(request: PermissionRequest, entryID: Int, onAnswer: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.entryID = entryID
        self.onAnswer = onAnswer
        message = Self.message(for: request)
        allowButton = NSButton(title: "Allow", target: nil, action: nil)
        blockButton = NSButton(title: "Block", target: nil, action: nil)
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: nil, action: nil)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.preferredMaxLayoutWidth = 264
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Neither answer is a default button: a Return meant for the page must never grant anything.
        allowButton.target = self
        allowButton.action = #selector(allow)
        blockButton.target = self
        blockButton.action = #selector(block)
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [label, closeButton])
        header.alignment = .top
        header.spacing = 8
        let buttons = NSStackView(views: [NSView(), blockButton, allowButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [header, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            background.widthAnchor.constraint(equalToConstant: 320),
        ])
        contentView = background
        setContentSize(background.fittingSize)
        setAccessibilityLabel(message)
    }

    @objc private func allow() { finish(.allow) }
    @objc private func block() { finish(.deny) }
    @objc private func dismiss() { finish(.dismiss) }

    private func finish(_ decision: PermissionDecision) {
        guard !answered else { return }
        answered = true
        onAnswer(decision)
    }

    /// "bow.test wants to use your camera and microphone".
    static func message(for request: PermissionRequest) -> String {
        let site = request.origin?.host ?? "This page"
        let order: [(PermissionKind, String)] = [
            (.camera, "use your camera"),
            (.microphone, "use your microphone"),
            (.screenCapture, "see your screen"),
            (.geolocation, "know your location"),
            (.notifications, "show notifications"),
            (.clipboard, "see text and images copied to the clipboard"),
            (.midiSysex, "control and reprogram your MIDI devices"),
            (.storageAccess, "use cookies and site data while embedded"),
            (.windowManagement, "manage windows on all your displays"),
            (.localFonts, "use the fonts on your computer"),
            (.other, "use a feature that needs your permission"),
        ]
        var phrases = order.filter { request.kinds.contains($0.0) }.map(\.1)
        if request.kinds.isSuperset(of: [.camera, .microphone]) {
            phrases.removeAll { $0 == "use your camera" || $0 == "use your microphone" }
            phrases.insert("use your camera and microphone", at: 0)
        }
        let list =
            phrases.count <= 1
            ? phrases.first ?? "use a feature that needs your permission"
            : phrases.dropLast().joined(separator: ", ") + " and " + phrases.last!
        return "\(site) wants to \(list)"
    }
}
