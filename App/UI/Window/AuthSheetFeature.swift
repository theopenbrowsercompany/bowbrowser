import AppKit
import BowCore

/// The sign in sheet: a site (or proxy) asking for a user name and password comes up as a sheet on the window while
/// the window shows the tab that asked, as Chrome's login prompt does (`SignInPolicy` holds the rules). It names who
/// asks, has a user name and a password field, Sign In (the default button) and Cancel. Sign In answers with what was
/// typed and the load goes on (a wrong password makes the server ask again); Cancel answers cancelled and the page
/// shows the site's own 401 page. A request from a tab the window does not show waits for its tab. Switching tabs takes
/// the sheet down and brings it back with its tab; a new navigation, a crash, closing the tab or the window, and
/// quitting cancel it. Nothing is saved: passwords stay with the engine's own sign in cache for the session.
@MainActor
final class AuthSheetFeature: NSResponder, BrowserWindowFeature {
    typealias Policy = SignInPolicy<TabID>

    static let signInTitle = "Sign In"
    static let cancelTitle = "Cancel"

    /// The sheet that is up: the request it shows, its alert and its two fields.
    struct Sheet {
        let id: Policy.RequestID
        let challenge: AuthChallenge
        let alert: NSAlert
        let user: NSTextField
        let password: NSSecureTextField
    }

    private weak var window: BrowserWindowController?
    private var policy = Policy()
    /// The loads waiting for an answer, by request.
    private var waiting: [Policy.RequestID: CheckedContinuation<AuthCredentials?, Never>] = [:]
    /// The sheet on the window, if a request is up.
    private(set) var sheet: Sheet?
    private let windowSheet: WindowSheet<Policy.RequestID>
    private var observers: [NSObjectProtocol] = []

    init(window: BrowserWindowController) {
        self.window = window
        windowSheet = WindowSheet(parent: window.window)
        super.init()
        windowSheet.retry = { [weak self] id in
            guard let self, self.policy.presented == id else { return }
            self.present(id)
        }
        // A closing tab (also each tab a closing window or quitting closes) has its request cancelled through
        // `tabDidClose`. The window closing and the app terminating cancel whatever is left, so no load waits on a
        // sheet nobody can see.
        let center = NotificationCenter.default
        if let nsWindow = window.window {
            observers.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: nsWindow, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.closeAll() }
                })
        }
        observers.append(
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.closeAll() }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        closeAll()
    }

    /// Whether `tab` has a sign in request up or waiting for its tab to be shown.
    func hasRequest(for tab: any EngineTab) -> Bool {
        policy.hasRequest(for: tab.tabID)
    }

    /// Whether no sign in request waits in this window.
    var isIdle: Bool { policy.isEmpty && waiting.isEmpty && sheet == nil }

    func answer(_ challenge: AuthChallenge, for tab: any EngineTab) async -> AuthCredentials? {
        // Nil (Cancel, or the request went) leaves it to the features after this one, and with none it is cancelled.
        await withCheckedContinuation { answer in
            let (id, actions) = policy.request(challenge, from: tab.tabID)
            waiting[id] = answer
            apply(actions)
        }
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        apply(policy.show(tab?.tabID))
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        // A request belongs to the load that asked: a new navigation leaves it, and a page whose render process
        // ended can no longer use the answer.
        switch event {
        case .didStartNavigation, .renderProcessGone: apply(policy.navigated(tab.tabID))
        default: break
        }
    }

    func tabDidClose(_ tab: any EngineTab) {
        apply(policy.closed(tab.tabID))
    }

    private func closeAll() {
        apply(policy.closeAll())
    }

    private func apply(_ actions: [Policy.Action]) {
        for action in actions {
            switch action {
            case .present(let id): present(id)
            case .dismiss(let id): dismiss(id)
            case .answer(let id, let credentials): waiting.removeValue(forKey: id)?.resume(returning: credentials)
            }
        }
    }

    private func present(_ id: Policy.RequestID) {
        guard let challenge = policy.challenge(id) else { return }
        let presented = windowSheet.present(
            id,
            makeAlert: {
                let alert = NSAlert()
                alert.messageText = AuthChallenge.sheetTitle
                alert.informativeText = challenge.sheetMessage
                // The first button is the default one (Return); Cancel also takes Escape.
                alert.addButton(withTitle: Self.signInTitle)
                alert.addButton(withTitle: Self.cancelTitle)
                let user = NSTextField(string: "")
                user.placeholderString = "User name"
                let password = NSSecureTextField(string: "")
                password.placeholderString = "Password"
                // Nothing offers to save or fill the password: saved passwords are later work.
                for field in [user, password] {
                    field.contentType = nil
                    field.frame.size = NSSize(width: 260, height: 22)
                    field.translatesAutoresizingMaskIntoConstraints = true
                }
                user.nextKeyView = password
                password.nextKeyView = user
                let stack = NSStackView(views: [user, password])
                stack.orientation = .vertical
                stack.spacing = 8
                stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
                alert.accessoryView = stack
                alert.window.initialFirstResponder = user
                sheet = Sheet(id: id, challenge: challenge, alert: alert, user: user, password: password)
                return alert
            },
            ended: { [weak self] response in self?.sheetEnded(id, response: response) })
        if !presented { apply(policy.answered(id, nil)) }
    }

    /// The person answered the sheet: Sign In (or Return) with what the fields hold, or Cancel (or Escape).
    private func sheetEnded(_ id: Policy.RequestID, response: NSApplication.ModalResponse) {
        guard let sheet, sheet.id == id else { return }
        self.sheet = nil
        let credentials =
            response == .alertFirstButtonReturn
            ? AuthCredentials(user: sheet.user.stringValue, password: sheet.password.stringValue) : nil
        apply(policy.answered(id, credentials))
    }

    private func dismiss(_ id: Policy.RequestID) {
        windowSheet.dismiss(id)
        if sheet?.id == id { sheet = nil }
    }
}
