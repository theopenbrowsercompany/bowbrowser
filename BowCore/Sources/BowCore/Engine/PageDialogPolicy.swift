import Foundation

// A page's JavaScript dialogs (alert, confirm, prompt): what the page asked and how it was answered. The page's
// "leave this site?" prompt is not one of these; the engine asks it itself (see `EngineTab.close()`).

/// Which dialog a page asked for.
public enum PageDialogKind: Equatable, Sendable {
    /// `alert()`: a message with OK.
    case alert
    /// `confirm()`: a question with OK and Cancel.
    case confirm
    /// `prompt()`: a question with a text field, OK and Cancel.
    case prompt
}

/// A page's alert, confirm or prompt.
public struct PageDialog: Equatable, Sendable {
    public var kind: PageDialogKind
    /// The origin of the frame that asked, or nil when the engine does not say.
    public var origin: URL?
    public var message: String
    /// The prompt field's starting text; empty unless `kind` is `.prompt`.
    public var defaultPromptText: String

    public init(kind: PageDialogKind, origin: URL?, message: String, defaultPromptText: String = "") {
        self.kind = kind
        self.origin = origin
        self.message = message
        self.defaultPromptText = defaultPromptText
    }

    /// The sheet's title, naming who asks as Chromium does: "<host> says" for a web origin (with its port when it is
    /// not the scheme's default), and "This page says" when there is no host to name (a file, `data:` or no origin).
    public var title: String {
        guard let origin, let scheme = origin.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = origin.host, !host.isEmpty
        else { return "This page says" }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = origin.port, port != defaultPort { return "\(host):\(port) says" }
        return "\(host) says"
    }
}

/// How a dialog was answered: OK (with the prompt's text) or Cancel.
public struct PageDialogAnswer: Equatable, Sendable {
    /// OK was chosen. An alert answered either way returns the same to the page.
    public var accepted: Bool
    /// The prompt field's text when OK was chosen on a prompt; nil otherwise.
    public var text: String?

    public init(accepted: Bool, text: String? = nil) {
        self.accepted = accepted
        self.text = accepted ? text : nil
    }

    /// OK without text.
    public static let ok = PageDialogAnswer(accepted: true)
    /// Cancel, also the answer to a dialog nobody saw: `confirm()` returns false and `prompt()` null.
    public static let cancelled = PageDialogAnswer(accepted: false)
}

extension EngineTabDelegate {
    public func tab(_ tab: any EngineTab, runDialog dialog: PageDialog) async -> PageDialogAnswer { .cancelled }
}

/// One window's page dialogs, following Chromium's tab-modal dialog rules
/// (components/javascript_dialogs/tab_modal_dialog_manager.cc, https://developer.chrome.com/blog/dialogs-policy):
///
/// - A dialog from the tab the window shows comes up at once, as a sheet on that window, and the page waits for it.
/// - An alert from a tab the window does not show is answered at once, so its page goes on, and waits: it comes up
///   when its tab is shown.
/// - A confirm or prompt from a tab the window does not show is cancelled at once (`false`, `null`) and never shows.
/// - Switching away from a tab whose dialog is up takes the sheet down: an alert is answered and waits for the tab to
///   be shown again; a confirm or prompt is cancelled.
/// - A new dialog from a tab replaces the tab's earlier one, which is cancelled.
/// - A tab that starts a new navigation or closes, a closing window and quitting cancel the tab's (or every) dialog.
///
/// A value the window feature drives: each call returns what to do, in order. `Tab` identifies a tab.
public struct PageDialogPolicy<Tab: Hashable> {
    /// Names one dialog for as long as the policy holds it.
    public struct DialogID: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: UInt64
        public var description: String { "dialog\(rawValue)" }
    }

    /// What the window does, in the order given.
    public enum Action: Equatable {
        /// Show the dialog as a sheet on the window.
        case present(DialogID)
        /// Take the dialog's sheet down without answering anything.
        case dismiss(DialogID)
        /// Answer the page that asked. Each dialog's page is answered exactly once.
        case answer(DialogID, PageDialogAnswer)
    }

    private struct Entry {
        let id: DialogID
        let tab: Tab
        let dialog: PageDialog
        /// Its page has had its answer (a waiting alert).
        var answered = false
        /// Its sheet is up.
        var presented = false
    }

    /// Held dialogs, oldest first: the one that is up, and alerts waiting for their tab. At most one per tab.
    private var entries: [Entry] = []
    private var nextID: UInt64 = 1
    /// The tab the window shows.
    public private(set) var shownTab: Tab?
    /// Set once the window closes or the app quits: every later dialog is cancelled at once.
    public private(set) var isClosed = false

    public init(shownTab: Tab? = nil) {
        self.shownTab = shownTab
    }

    /// The dialog `id` names, while the policy holds it.
    public func dialog(_ id: DialogID) -> PageDialog? {
        entries.first { $0.id == id }?.dialog
    }

    /// The dialog whose sheet is up, if any.
    public var presented: DialogID? {
        entries.first { $0.presented }?.id
    }

    /// Whether `tab` has a dialog up or waiting, which an unload would take away unseen.
    public func hasDialog(for tab: Tab) -> Bool {
        entries.contains { $0.tab == tab }
    }

    /// `tab`'s page asked for `dialog`. Returns its ID (also for one answered at once) and what to do.
    public mutating func request(_ dialog: PageDialog, from tab: Tab) -> (DialogID, [Action]) {
        let id = DialogID(rawValue: nextID)
        nextID += 1
        guard !isClosed else { return (id, [.answer(id, .cancelled)]) }
        var actions = close(where: { $0.tab == tab })
        var entry = Entry(id: id, tab: tab, dialog: dialog)
        if tab == shownTab {
            entry.presented = true
            entries.append(entry)
            actions.append(.present(id))
        } else if dialog.kind == .alert {
            entry.answered = true
            entries.append(entry)
            actions.append(.answer(id, .ok))
        } else {
            actions.append(.answer(id, .cancelled))
        }
        return (id, actions)
    }

    /// The window now shows `tab` (nil for none).
    public mutating func show(_ tab: Tab?) -> [Action] {
        guard tab != shownTab, !isClosed else { return [] }
        var actions: [Action] = []
        if let index = entries.firstIndex(where: { $0.presented }) {
            let entry = entries[index]
            actions.append(.dismiss(entry.id))
            if entry.dialog.kind == .alert {
                entries[index].presented = false
                if !entry.answered {
                    entries[index].answered = true
                    actions.append(.answer(entry.id, .ok))
                }
            } else {
                entries.remove(at: index)
                actions.append(.answer(entry.id, .cancelled))
            }
        }
        shownTab = tab
        if let tab, let index = entries.firstIndex(where: { $0.tab == tab }) {
            entries[index].presented = true
            actions.append(.present(entries[index].id))
        }
        return actions
    }

    /// The person answered dialog `id` through its sheet, which is already down. Ignored for a dialog the policy no
    /// longer holds or whose sheet is not up.
    public mutating func answered(_ id: DialogID, _ answer: PageDialogAnswer) -> [Action] {
        guard let index = entries.firstIndex(where: { $0.id == id && $0.presented }) else { return [] }
        let entry = entries.remove(at: index)
        return entry.answered ? [] : [.answer(id, answer)]
    }

    /// `tab` started a new navigation: its dialog belonged to the page it is leaving.
    public mutating func navigated(_ tab: Tab) -> [Action] {
        close(where: { $0.tab == tab })
    }

    /// `tab` closed (or unloaded).
    public mutating func closed(_ tab: Tab) -> [Action] {
        if tab == shownTab { shownTab = nil }
        return close(where: { $0.tab == tab })
    }

    /// The window is closing, or the app is quitting: every dialog is cancelled, and later ones are cancelled at once.
    public mutating func closeAll() -> [Action] {
        isClosed = true
        shownTab = nil
        return close(where: { _ in true })
    }

    private mutating func close(where matches: (Entry) -> Bool) -> [Action] {
        var actions: [Action] = []
        for entry in entries where matches(entry) {
            if entry.presented { actions.append(.dismiss(entry.id)) }
            if !entry.answered { actions.append(.answer(entry.id, .cancelled)) }
        }
        entries.removeAll(where: matches)
        return actions
    }
}
