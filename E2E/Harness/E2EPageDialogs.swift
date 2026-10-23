import Foundation

/// A window's page dialogs (alert, confirm, prompt) as a test sees them: the sheet the window shows and its
/// buttons, answered the way a person answers it, never through the app's modal session.
/// E2E/Harness/E2EAppAdapter+PageDialogs.swift implements it; every action is refused once the test has ended.
@MainActor
protocol E2EPageDialogsApp: E2EApp {
    /// The page dialog up as a sheet on `page`'s window, or nil when none is.
    func pageDialog(besides page: any E2EPage) throws -> E2EPageDialog?
    /// Whether `page`'s tab has a dialog up or waiting for its tab to be shown.
    func pageDialogWaits(for page: any E2EPage) throws -> Bool
    /// Presses OK on the dialog up on `page`'s window, typing `text` into a prompt's field first when given, or
    /// Cancel when `accept` is false. Throws when no dialog is up.
    func answerPageDialog(besides page: any E2EPage, accept: Bool, text: String?) throws
    /// Whether the app runs a modal panel (an app modal dialog), which no page dialog may ever be.
    var appModalPanelShown: Bool { get }
}

/// A page dialog's sheet as a test reads it.
struct E2EPageDialog: Equatable, CustomStringConvertible {
    var title: String
    var message: String
    /// Its buttons' titles, in order.
    var buttons: [String]
    /// A prompt's text field contents; nil without a field.
    var field: String?
    /// The sheet is attached to the window (not queued or floating).
    var isAttached: Bool

    var description: String {
        "title=\"\(title)\" message=\"\(message)\" buttons=\(buttons.joined(separator: "+"))"
            + (field.map { " field=\"\($0)\"" } ?? "") + (isAttached ? "" : " detached")
    }
}
