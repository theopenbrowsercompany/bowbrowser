import AppKit
import BowCore

/// The sign in requests of one window as sheets on it: `SignInPolicy` decides, this puts the sheet up through the
/// window's `WindowSheet` presenter (the one the page dialogs use) and answers the load. A browser window's
/// `AuthSheetFeature` and each popup panel own one, so a panel's sign in follows the same rules and the same sheet as a
/// tab's. The owner tells it which tab the window shows (`show`) and when a tab navigates or closes; the window closing
/// and the app quitting cancel whatever is left, and so does `close`, which the owner calls before the window goes.
@MainActor
final class SignInSheets {
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

    private var policy: Policy
    /// The loads waiting for an answer, by request.
    private var waiting: [Policy.RequestID: CheckedContinuation<AuthCredentials?, Never>] = [:]
    /// The sheet on the window, if a request is up.
    private(set) var sheet: Sheet?
    private let windowSheet: WindowSheet<Policy.RequestID>
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow?, shownTab: TabID? = nil) {
        windowSheet = WindowSheet(parent: window)
        policy = Policy(shownTab: shownTab)
        // A request that had to wait for another sheet comes up once that one ends, if its tab still shows.
        windowSheet.retry = { [weak self] id in
            guard let self, self.policy.presented == id else { return }
            self.present(id)
        }
        // A closing tab has its request cancelled through `closed`. The window closing and the app terminating cancel
        // whatever is left, so no load waits on a sheet nobody can see.
        let center = NotificationCenter.default
        if let window {
            observers.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                })
        }
        observers.append(
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        close()
    }

    /// Whether `tab` has a sign in request up or waiting for its tab to be shown.
    func hasRequest(for tab: TabID) -> Bool {
        policy.hasRequest(for: tab)
    }

    /// Whether no sign in request waits and no sheet is up.
    var isIdle: Bool { policy.isEmpty && waiting.isEmpty && sheet == nil }

    /// The answer to `challenge` from `tab`: what the person typed and Sign In, or nil for Cancel or a request that
    /// went (a navigation, a close, quitting).
    func answer(_ challenge: AuthChallenge, for tab: TabID) async -> AuthCredentials? {
        await withCheckedContinuation { answer in
            let (id, actions) = policy.request(challenge, from: tab)
            waiting[id] = answer
            apply(actions)
        }
    }

    func show(_ tab: TabID?) {
        apply(policy.show(tab))
    }

    /// `tab` started a navigation or lost its render process: its request belonged to the load it left.
    func navigated(_ tab: TabID) {
        apply(policy.navigated(tab))
    }

    func closed(_ tab: TabID) {
        apply(policy.closed(tab))
    }

    /// Cancels every request, takes the sheet down and cancels every later request at once. The window must not
    /// close before this: AppKit refuses to close a window with a sheet up.
    func close() {
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
                // The first button is the sheet's default button (Return); Cancel takes Escape.
                alert.addButton(withTitle: Self.signInTitle)
                alert.addButton(withTitle: Self.cancelTitle)
                let user = NSTextField(string: "")
                user.placeholderString = "User name"
                let password = NSSecureTextField(string: "")
                password.placeholderString = "Password"
                // Nothing offers to save or fill the password: saved passwords are later work.
                for field in [user, password] { field.contentType = nil }
                // Fixed frames, as the page dialogs' prompt field has: the alert lays its accessory view out by frame.
                user.frame = NSRect(x: 0, y: 30, width: 260, height: 22)
                password.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
                user.nextKeyView = password
                password.nextKeyView = user
                let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
                fields.addSubview(user)
                fields.addSubview(password)
                alert.accessoryView = fields
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
