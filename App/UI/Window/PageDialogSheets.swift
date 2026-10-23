import AppKit
import BowCore

/// The page dialogs of one window as sheets on it: `PageDialogPolicy` decides, this puts the sheet up through the
/// window's `WindowSheet` presenter (the one the sign in sheet uses) and answers the page. A browser window's
/// `PageDialogsFeature` and each popup panel own one, so a panel's alert, confirm and prompt follow the same rules and
/// the same sheet as a tab's. The owner tells it which tab the window shows (`show`) and when a tab navigates or
/// closes, and calls `close` before the window goes.
@MainActor
final class PageDialogSheets {
    typealias Policy = PageDialogPolicy<TabID>

    /// The sheet that is up: the dialog it shows, its alert and, for a prompt, its text field.
    struct Sheet {
        let id: Policy.DialogID
        let dialog: PageDialog
        let alert: NSAlert
        let field: NSTextField?
    }

    private var policy = Policy()
    /// The pages waiting for an answer, by dialog.
    private var waiting: [Policy.DialogID: CheckedContinuation<PageDialogAnswer, Never>] = [:]
    /// The sheet on the window, if a dialog is up.
    private(set) var sheet: Sheet?
    private let windowSheet: WindowSheet<Policy.DialogID>
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow?, shownTab: TabID? = nil) {
        windowSheet = WindowSheet(parent: window)
        policy = Policy(shownTab: shownTab)
        // A dialog that had to wait for another sheet (a leave prompt) comes up once that one ends, if the policy still
        // has it up.
        windowSheet.retry = { [weak self] id in
            guard let self, self.policy.presented == id else { return }
            self.present(id)
        }
        // The window closing and the app terminating answer whatever is left, so no page is left waiting on a sheet
        // nobody can see.
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

    /// Whether `tab` has a dialog up or waiting for its tab to be shown, which unloading it would take away unseen.
    func hasDialog(for tab: TabID) -> Bool {
        policy.hasDialog(for: tab)
    }

    func run(_ dialog: PageDialog, for tab: TabID) async -> PageDialogAnswer {
        await withCheckedContinuation { answer in
            let (id, actions) = policy.request(dialog, from: tab)
            waiting[id] = answer
            apply(actions)
        }
    }

    func show(_ tab: TabID?) {
        apply(policy.show(tab))
    }

    /// The window now shows `tabs`, one per pane: a dialog from any of them comes up, focused pane or not.
    func show(_ tabs: [TabID]) {
        apply(policy.show(tabs))
    }

    /// The tab whose dialog the sheet on the window shows, nil while none is up.
    var sheetTab: TabID? {
        sheet.flatMap { policy.tab(of: $0.id) }
    }

    /// `tab` started a navigation or lost its render process: its dialog belonged to the page it is leaving.
    func navigated(_ tab: TabID) {
        apply(policy.navigated(tab))
    }

    func closed(_ tab: TabID) {
        apply(policy.closed(tab))
    }

    /// Answers every dialog as cancelled, takes the sheet down and cancels every later dialog at once. The window
    /// must not close before this: AppKit refuses to close a window with a sheet up.
    func close() {
        apply(policy.closeAll())
    }

    private func apply(_ actions: [Policy.Action]) {
        for action in actions {
            switch action {
            case .present(let id): present(id)
            case .dismiss(let id): dismiss(id)
            case .answer(let id, let answer): waiting.removeValue(forKey: id)?.resume(returning: answer)
            }
        }
    }

    private func present(_ id: Policy.DialogID) {
        guard let dialog = policy.dialog(id) else {
            apply(policy.answered(id, .cancelled))
            return
        }
        let presented = windowSheet.present(
            id,
            makeAlert: {
                let alert = NSAlert()
                alert.messageText = dialog.title
                alert.informativeText = dialog.message
                alert.addButton(withTitle: "OK")
                if dialog.kind != .alert { alert.addButton(withTitle: "Cancel") }
                var field: NSTextField?
                if dialog.kind == .prompt {
                    let input = NSTextField(string: dialog.defaultPromptText)
                    input.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
                    alert.accessoryView = input
                    alert.window.initialFirstResponder = input
                    field = input
                }
                sheet = Sheet(id: id, dialog: dialog, alert: alert, field: field)
                return alert
            },
            ended: { [weak self] response in self?.sheetEnded(id, response: response) })
        // No window to show it on: the page gets Cancel.
        if !presented { apply(policy.answered(id, .cancelled)) }
    }

    /// The person answered the sheet (OK, Cancel, or Escape for Cancel).
    private func sheetEnded(_ id: Policy.DialogID, response: NSApplication.ModalResponse) {
        guard let sheet, sheet.id == id else { return }
        self.sheet = nil
        let accepted = sheet.dialog.kind == .alert || response == .alertFirstButtonReturn
        apply(policy.answered(id, PageDialogAnswer(accepted: accepted, text: sheet.field?.stringValue)))
    }

    private func dismiss(_ id: Policy.DialogID) {
        windowSheet.dismiss(id)
        if sheet?.id == id { sheet = nil }
    }
}
