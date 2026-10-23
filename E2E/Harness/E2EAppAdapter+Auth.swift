import AppKit
import BowCore

// The sign in and certificate error area of the adapter: E2EAuthApp over the window's AuthSheetFeature, the sheet it
// puts on the window, and CertificateErrorFeature's page over the page area. Both are answered by pressing their own
// buttons as a person does, so the press runs the same action the button runs for a click.

extension E2ETestApp: E2EAuthApp {
    func signInSheet(besides page: any E2EPage) throws -> E2ESignInSheet? {
        try adapter.requireActive(token, "read the sign in sheet")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sheet = controller.feature(AuthSheetFeature.self)?.sheet else { return nil }
        let alert = sheet.alert
        return E2ESignInSheet(
            title: alert.messageText, message: alert.informativeText, buttons: alert.buttons.map(\.title),
            defaultButton: alert.window.defaultButtonCell?.title ?? "",
            fieldsReady: sheet.user.stringValue.isEmpty && sheet.password.stringValue.isEmpty,
            isAttached: controller.window != nil && alert.window.sheetParent === controller.window,
            offScreen: [controller.window, alert.window].allSatisfy { window in
                guard let frame = window?.frame else { return true }
                return !NSScreen.screens.contains { $0.frame.intersects(frame) }
            })
    }

    func signInWaits(for page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the sign in requests")
        let tabPage = try E2EAppAdapter.tabPage(page)
        return tabPage.controller.feature(AuthSheetFeature.self)?.hasRequest(for: tabPage.tab) ?? false
    }

    func signInIdle(besides page: any E2EPage) throws -> Bool {
        try adapter.requireActive(token, "read the sign in requests")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let feature = controller.feature(AuthSheetFeature.self) else { return false }
        return feature.isIdle && controller.window?.attachedSheet == nil
    }

    func answerSignInSheet(besides page: any E2EPage, user: String?, password: String?) throws {
        try adapter.requireActive(token, "answer the sign in sheet")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let sheet = controller.feature(AuthSheetFeature.self)?.sheet else {
            throw E2EError("no sign in sheet is up")
        }
        let buttons = sheet.alert.buttons
        if let user {
            sheet.user.stringValue = user
            sheet.password.stringValue = password ?? ""
            guard let signIn = buttons.first, signIn.title == AuthSheetFeature.signInTitle else {
                throw E2EError("the sheet has no \(AuthSheetFeature.signInTitle) button")
            }
            signIn.performClick(nil)
        } else {
            guard let cancel = buttons.dropFirst().first, cancel.title == AuthSheetFeature.cancelTitle else {
                throw E2EError("the sheet has no \(AuthSheetFeature.cancelTitle) button")
            }
            cancel.performClick(nil)
        }
    }

    func certificateErrorPage(besides page: any E2EPage) throws -> E2ECertificateErrorPage? {
        try adapter.requireActive(token, "read the certificate error page")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let view = controller.feature(CertificateErrorFeature.self)?.errorView, !view.isHiddenOrHasHiddenAncestor
        else { return nil }
        return E2ECertificateErrorPage(
            title: view.titleLabel.stringValue, message: view.messageLabel.stringValue,
            detail: view.detailLabel.stringValue,
            buttons: E2EAppAdapter.views(in: view, NSButton.self).map(\.title))
    }

    func pressCertificateGoBack(besides page: any E2EPage) throws {
        try adapter.requireActive(token, "press Go back")
        let controller = try E2EAppAdapter.tabPage(page).controller
        guard let view = controller.feature(CertificateErrorFeature.self)?.errorView, !view.isHiddenOrHasHiddenAncestor
        else { throw E2EError("no certificate error page shows") }
        view.goBackButton.performClick(nil)
    }
}
