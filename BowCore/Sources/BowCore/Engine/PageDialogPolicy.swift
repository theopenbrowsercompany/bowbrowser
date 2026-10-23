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
