import AppKit
import BowCore

// The page dialogs area of the adapter: E2EPageDialogsApp over the window's PageDialogsFeature and the sheet it puts
// on the window (and the popup panel's, over the panel's PageDialogSheets), answered by pressing the sheet's own
// buttons as a person does.

extension E2ETestApp: E2EPageDialogsApp {
    func pageDialog(besides page: any E2EPage) throws -> E2EPageDialog? {
        try adapter.requireActive(token, "read the page dialog")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sheet = controller.feature(PageDialogsFeature.self)?.sheet else { return nil }
        return Self.describe(sheet, on: controller.window)
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
        try Self.press(sheet, accept: accept, text: text)
    }

    func panelDialog(besides page: any E2EPage) throws -> E2EPageDialog? {
        try adapter.requireActive(token, "read the popup panel's dialog")
        guard let panel = try Self.newestPanel(besides: page), let sheet = panel.dialogs.sheet else { return nil }
        return Self.describe(sheet, on: panel.window)
    }

    func panelDialogIsOffScreen(besides page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the popup panel's dialog")
        guard let panel = try Self.newestPanel(besides: page), let sheet = panel.dialogs.sheet else {
            throw E2EError("no popup panel dialog is up")
        }
        let frames = [panel.window.frame, sheet.alert.window.frame]
        return frames.allSatisfy { frame in !NSScreen.screens.contains { $0.frame.intersects(frame) } }
    }

    func answerPanelDialog(besides page: any E2EPage, accept: Bool, text: String?) throws {
        try adapter.requireActive(token, "answer the popup panel's dialog")
        guard let panel = try Self.newestPanel(besides: page), let sheet = panel.dialogs.sheet else {
            throw E2EError("no popup panel dialog is up")
        }
        try Self.press(sheet, accept: accept, text: text)
    }

    var appModalPanelShown: Bool { NSApp.modalWindow != nil }

    private static func newestPanel(besides page: any E2EPage) throws -> PopupPanel? {
        let controller = try E2EAppAdapter.tabPage(page).controller
        return (controller.window?.childWindows ?? []).compactMap { $0.delegate as? PopupPanel }.last
    }

    private static func describe(_ sheet: PageDialogSheets.Sheet, on window: NSWindow?) -> E2EPageDialog {
        let alert = sheet.alert
        return E2EPageDialog(
            title: alert.messageText, message: alert.informativeText, buttons: alert.buttons.map(\.title),
            field: sheet.field?.stringValue,
            isAttached: window != nil && alert.window.sheetParent === window)
    }

    private static func press(_ sheet: PageDialogSheets.Sheet, accept: Bool, text: String?) throws {
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
}
