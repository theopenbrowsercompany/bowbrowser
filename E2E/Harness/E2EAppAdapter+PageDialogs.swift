import AppKit
import BowCore

// The page dialogs area of the adapter: E2EPageDialogsApp over the window's PageDialogsFeature and the sheet it puts
// on the window, answered by pressing the sheet's own buttons as a person does.

extension E2ETestApp: E2EPageDialogsApp {
    func pageDialog(besides page: any E2EPage) throws -> E2EPageDialog? {
        try adapter.requireActive(token, "read the page dialog")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sheet = controller.feature(PageDialogsFeature.self)?.sheet else { return nil }
        let alert = sheet.alert
        return E2EPageDialog(
            title: alert.messageText, message: alert.informativeText, buttons: alert.buttons.map(\.title),
            field: sheet.field?.stringValue,
            isAttached: controller.window != nil && alert.window.sheetParent === controller.window)
    }

    func pageDialogWaits(for page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the page dialogs")
        let tabPage = try E2EAppAdapter.tabPage(page)
        return tabPage.controller.feature(PageDialogsFeature.self)?.hasDialog(for: tabPage.tab) ?? false
    }

    func answerPageDialog(besides page: any E2EPage, accept: Bool, text: String?) throws {
        try adapter.requireActive(token, "answer the page dialog")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sheet = controller.feature(PageDialogsFeature.self)?.sheet else {
            throw E2EError("no page dialog is up")
        }
        if let text {
            guard let field = sheet.field else { throw E2EError("the dialog has no text field") }
            field.stringValue = text
        }
        let buttons = sheet.alert.buttons
        guard let button = accept ? buttons.first : buttons.dropFirst().first else {
            throw E2EError("the dialog has no \(accept ? "OK" : "Cancel") button")
        }
        button.performClick(nil)
    }

    var appModalPanelShown: Bool { NSApp.modalWindow != nil }
}
