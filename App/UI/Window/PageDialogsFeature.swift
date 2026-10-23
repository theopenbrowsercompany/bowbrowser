import AppKit
import BowCore

/// A page's alert, confirm and prompt, scoped to its tab as Chromium scopes them (`PageDialogPolicy` holds the
/// rules): a sheet on the window while the window shows the tab that asked, never an app modal panel. An alert from a
/// tab the window does not show is answered at once and comes up when its tab is shown; a confirm or prompt from one
/// is cancelled. Switching tabs, a new navigation, closing the tab or the window, and quitting take the sheet down.
/// The tab's "leave this site?" prompt is not one of these: the tab asks it itself.
@MainActor
final class PageDialogsFeature: NSResponder, BrowserWindowFeature {
    typealias Policy = PageDialogPolicy<TabID>

    /// The sheet that is up: the dialog it shows, its alert and, for a prompt, its text field.
    struct Sheet {
        let id: Policy.DialogID
        let dialog: PageDialog
        let alert: NSAlert
        let field: NSTextField?
    }

    private weak var window: BrowserWindowController?
    private var policy = Policy()
    /// The pages waiting for an answer, by dialog.
    private var waiting: [Policy.DialogID: CheckedContinuation<PageDialogAnswer, Never>] = [:]
    /// The sheet on the window, if a dialog is up.
    private(set) var sheet: Sheet?
    /// The dialog that is up for the policy but waits for another sheet on the window to end.
    private var deferred: Policy.DialogID?
    private var observers: [NSObjectProtocol] = []

    init(window: BrowserWindowController) {
        self.window = window
        super.init()
        // A closing tab (also each tab a closing window or quitting closes) has its dialog cancelled through
        // `tabDidClose`, and the engine lets a page with a dialog up close. The window closing and the app
        // terminating answer whatever is left, so no page is left waiting on a sheet nobody can see.
        let center = NotificationCenter.default
        if let nsWindow = window.window {
            observers.append(
                center.addObserver(forName: NSWindow.willCloseNotification, object: nsWindow, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.closeAll() }
                })
            // A sheet that had to wait for another one (a leave prompt) comes up once that one ends.
            observers.append(
                center.addObserver(forName: NSWindow.didEndSheetNotification, object: nsWindow, queue: .main) {
                    [weak self] _ in
                    // On the next turn, once AppKit has let go of the ended sheet.
                    Task { @MainActor in self?.presentDeferred() }
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

    /// Whether `tab` has a dialog up or waiting for its tab to be shown, which unloading it would take away unseen.
    func hasDialog(for tab: any EngineTab) -> Bool {
        policy.hasDialog(for: tab.tabID)
    }

    func runDialog(_ dialog: PageDialog, for tab: any EngineTab) async -> PageDialogAnswer? {
        await withCheckedContinuation { answer in
            let (id, actions) = policy.request(dialog, from: tab.tabID)
            waiting[id] = answer
            apply(actions)
        }
    }

    func selectedTabChanged(_ tab: (any EngineTab)?) {
        apply(policy.show(tab?.tabID))
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        // A dialog belongs to the page that asked; a navigation leaves it (as Chromium, also one that never
        // commits), and a page whose render process ended can no longer hear the answer.
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
            case .answer(let id, let answer): waiting.removeValue(forKey: id)?.resume(returning: answer)
            }
        }
    }

    private func present(_ id: Policy.DialogID) {
        guard let dialog = policy.dialog(id), let parent = window?.window else {
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
        alert.beginSheetModal(for: parent) { [weak self] response in
            MainActor.assumeIsolated { self?.sheetEnded(id, response: response) }
        }
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
        guard let id = deferred, sheet == nil, window?.window?.attachedSheet == nil else { return }
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
