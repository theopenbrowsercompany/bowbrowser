import AppKit
import BowCore

/// The page dialogs of one window as sheets on it: `PageDialogPolicy` decides, this puts the sheet up and answers the
/// page. A browser window's `PageDialogsFeature` and each popup panel own one, so a panel's alert, confirm and prompt
/// follow the same rules and the same sheet as a tab's. The owner tells it which tab the window shows
/// (`show`) and when a tab navigates or closes, and calls `close` before the window goes.
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

    private weak var window: NSWindow?
    private var policy = Policy()
    /// The pages waiting for an answer, by dialog.
    private var waiting: [Policy.DialogID: CheckedContinuation<PageDialogAnswer, Never>] = [:]
    /// The sheet on the window, if a dialog is up.
    private(set) var sheet: Sheet?
    /// The dialog that is up for the policy but waits for another sheet on the window to end.
    private var deferred: Policy.DialogID?
    private var observers: [NSObjectProtocol] = []

    init(window: NSWindow?, shownTab: TabID? = nil) {
        self.window = window
        policy = Policy(shownTab: shownTab)
        // The window closing and the app terminating answer whatever is left, so no page is left waiting on a sheet
        // nobody can see.
        let center = NotificationCenter.default
        if let window {
            observers.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                })
            // A sheet that had to wait for another one (a leave prompt) comes up once that one ends.
            observers.append(
                center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) {
                    [weak self] _ in
                    // On the next turn, once AppKit has let go of the ended sheet.
                    Task { @MainActor in self?.presentDeferred() }
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
        guard let dialog = policy.dialog(id), let parent = window else {
            apply(policy.answered(id, .cancelled))
            return
        }
        // AppKit would queue a second sheet where nothing can take it down again, so the dialog waits for the
        // window's sheet to end.
        guard parent.attachedSheet == nil else {
            deferred = id
            return
        }
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
        // Putting a sheet up can bring a window that sits where no screen shows (an e2e window kept off every screen)
        // onto the main screen, so the window goes back where it was. A window on a screen does not move.
        let frame = parent.frame
        alert.beginSheetModal(for: parent) { [weak self] response in
            MainActor.assumeIsolated { self?.sheetEnded(id, response: response) }
        }
        if parent.frame != frame { parent.setFrame(frame, display: false) }
    }

    /// The person answered the sheet (OK, Cancel, or Escape for Cancel).
    private func sheetEnded(_ id: Policy.DialogID, response: NSApplication.ModalResponse) {
        guard let sheet, sheet.id == id else { return }
        self.sheet = nil
        let accepted = sheet.dialog.kind == .alert || response == .alertFirstButtonReturn
        apply(policy.answered(id, PageDialogAnswer(accepted: accepted, text: sheet.field?.stringValue)))
    }

    /// Presents the dialog that waited for another sheet, if the policy still has it up.
    private func presentDeferred() {
        guard let id = deferred, sheet == nil, window?.attachedSheet == nil else { return }
        deferred = nil
        if policy.presented == id { present(id) }
    }

    private func dismiss(_ id: Policy.DialogID) {
        if deferred == id { deferred = nil }
        guard let sheet, sheet.id == id else { return }
        self.sheet = nil
        let sheetWindow = sheet.alert.window
        sheetWindow.sheetParent?.endSheet(sheetWindow, returnCode: .abort)
    }
}
