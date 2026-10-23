import AppKit
import BowCore

/// Answers one window's permission requests: from the profile's remembered answers when it has one, otherwise by
/// asking the person in a prompt anchored to the top of the page, then remembering their answer per site in the
/// profile's store and in the engine's content settings.
///
/// Requests wait in order. The prompt shows the first request of the tab the window shows; switching tabs hides it
/// and shows that tab's own, and a request whose tab closes or leaves the page is dismissed.
@MainActor
final class PermissionPrompts {
    private struct Pending {
        let id: Int
        let tab: any EngineTab
        let request: PermissionRequest
        let answer: CheckedContinuation<PermissionDecision, Never>
    }

    private let store: SitePermissionStore
    private let profile: any EngineProfile
    /// The view the prompt is anchored to: the page's view.
    private unowned let hostView: NSView
    private var pending: [Pending] = []
    private var lastPendingID = 0
    /// The prompt on screen, showing `pending`'s first request of `shownTab`.
    private(set) var visiblePrompt: PermissionPromptPanel?
    private weak var shownTab: (any EngineTab)?
    private var frameObserver: NSObjectProtocol?

    init(store: SitePermissionStore, profile: any EngineProfile, hostView: NSView) {
        self.store = store
        self.profile = profile
        self.hostView = hostView
        hostView.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: hostView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePrompt() }
        }
    }

    isolated deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        visiblePrompt?.close()
    }

    /// The answer to `request` from `tab`: remembered, or the person's once they answer the prompt.
    func decide(_ request: PermissionRequest, for tab: any EngineTab) async -> PermissionDecision {
        if let remembered = store.decision(for: request) { return remembered }
        return await withCheckedContinuation { answer in
            lastPendingID += 1
            pending.append(Pending(id: lastPendingID, tab: tab, request: request, answer: answer))
            update()
        }
    }

    /// Shows the prompt for `tab`, the tab the window now shows (nil when none).
    func show(_ tab: (any EngineTab)?) {
        shownTab = tab
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

    /// The person answered the prompt for the first request of the shown tab.
    private func answer(_ decision: PermissionDecision) {
        guard let index = pending.firstIndex(where: { $0.tab === shownTab }) else { return }
        let answered = pending.remove(at: index)
        remember(decision, for: answered.request)
        answered.answer.resume(returning: decision)
        // The answer may settle other waiting requests from the same site.
        let settled = pending.compactMap { entry in store.decision(for: entry.request).map { (entry, $0) } }
        pending.removeAll { entry in settled.contains { $0.0.id == entry.id } }
        for (entry, decision) in settled { entry.answer.resume(returning: decision) }
        update()
    }

    private func remember(_ decision: PermissionDecision, for request: PermissionRequest) {
        let stored: [PermissionKind: SitePermissionSetting]
        do {
            stored = try store.record(decision, for: request)
        } catch {
            // The answer still holds while the app runs; it is asked again after a restart.
            NSLog("Bow: could not save a permission answer: %@", String(describing: error))
            return
        }
        guard let site = request.site else { return }
        for (kind, setting) in stored { profile.setPermission(setting, for: kind, on: site) }
    }

    private func update() {
        let request = pending.first { $0.tab === shownTab }?.request
        let entryID = pending.first { $0.tab === shownTab }?.id
        if let prompt = visiblePrompt, prompt.entryID != entryID {
            prompt.parent?.removeChildWindow(prompt)
            prompt.close()
            visiblePrompt = nil
        }
        guard let request, let entryID, visiblePrompt == nil, let window = hostView.window else { return }
        let prompt = PermissionPromptPanel(request: request, entryID: entryID) { [weak self] decision in
            self?.answer(decision)
        }
        visiblePrompt = prompt
        placePrompt()
        window.addChildWindow(prompt, ordered: .above)
    }

    /// Puts the prompt at the top leading corner of the page, inset a little, as macOS browsers place theirs.
    private func placePrompt() {
        guard let prompt = visiblePrompt, let window = hostView.window else { return }
        let inset: CGFloat = 12
        let topLeft = window.convertPoint(toScreen: hostView.convert(NSPoint(x: hostView.bounds.minX, y: hostView.bounds.maxY), to: nil))
        let size = prompt.frame.size
        let origin = NSPoint(x: topLeft.x + inset, y: topLeft.y - inset - size.height)
        prompt.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

/// The prompt itself: a small borderless panel attached to the browser window, naming the site and what it asks
/// for, with Block and Allow. It never activates the app or takes the keyboard from the page.
@MainActor
final class PermissionPromptPanel: NSPanel {
    let request: PermissionRequest
    /// Which waiting request this prompt answers.
    fileprivate let entryID: Int
    let message: String
    let allowButton: NSButton
    let blockButton: NSButton
    private let onAnswer: (PermissionDecision) -> Void
    private var answered = false

    fileprivate init(request: PermissionRequest, entryID: Int, onAnswer: @escaping (PermissionDecision) -> Void) {
        self.request = request
        self.entryID = entryID
        self.onAnswer = onAnswer
        message = Self.message(for: request)
        allowButton = NSButton(title: "Allow", target: nil, action: nil)
        blockButton = NSButton(title: "Block", target: nil, action: nil)
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
        label.preferredMaxLayoutWidth = 288
        allowButton.target = self
        allowButton.action = #selector(allow)
        allowButton.keyEquivalent = "\r"
        blockButton.target = self
        blockButton.action = #selector(block)
        let buttons = NSStackView(views: [NSView(), blockButton, allowButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            background.widthAnchor.constraint(equalToConstant: 320),
        ])
        contentView = background
        setContentSize(background.fittingSize)
        setAccessibilityLabel(message)
    }

    @objc private func allow() { finish(.allow) }
    @objc private func block() { finish(.deny) }

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
