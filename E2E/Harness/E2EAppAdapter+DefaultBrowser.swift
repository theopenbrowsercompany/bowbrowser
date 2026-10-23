import AppKit
import BowCore

// The default browser area of the adapter: Bow > Set as Default Browser, chosen through the app menu with the system's
// registration replaced by a recorder. The e2e build has no real registrar at all (BlockedDefaultBrowserRegistrar),
// so a test can only reach the recorder.

/// A stand in for the system's default browser registration, which a test sets up with what the system answers.
@MainActor
final class E2EDefaultBrowserRecorder: DefaultBrowserRegistrar {
    /// The app the system says opens http links.
    var handler: URL?
    /// What the system refuses with, nil to accept.
    var failure: NSError?
    /// While true, a registration waits (the system's prompt is up) until `release()`.
    var holds = false
    /// Every registration asked for, as "scheme path".
    private(set) var calls: [String] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func defaultHandler(forScheme scheme: String) -> URL? { handler }

    func register(bundleURL: URL, scheme: String) async throws {
        calls.append("\(scheme) \(bundleURL.path)")
        if holds {
            await withCheckedContinuation { waiting = $0 }
        }
        if let failure { throw failure }
    }

    func release() {
        holds = false
        waiting?.resume()
        waiting = nil
    }
}

/// The Set as Default Browser item as a test reads it.
struct E2EDefaultBrowserItem: Equatable, CustomStringConvertible {
    var title: String
    var enabled: Bool
    var description: String { "title=\"\(title)\" enabled=\(enabled)" }
}

/// The failure alert a registration puts up as a sheet.
struct E2EDefaultBrowserAlert: Equatable, CustomStringConvertible {
    var title: String
    var detail: String
    var buttons: [String]
    var isAttached: Bool
    var description: String { "title=\"\(title)\" detail=\"\(detail)\" buttons=\(buttons.joined(separator: "+"))" }
}

@MainActor
protocol E2EDefaultBrowserApp: E2EApp {
    /// Replaces the system's registration with a recorder that answers `handler` for http, refuses with `failure` when
    /// given, and holds each registration until `releaseDefaultBrowserRegistration()` when `holds`; failure alerts come
    /// up on `page`'s window. Undone by `removeDefaultBrowserRecorder()`.
    func installDefaultBrowserRecorder(handler: URL?, failure: NSError?, holds: Bool, besides page: any E2EPage) throws
    func removeDefaultBrowserRecorder()
    func releaseDefaultBrowserRegistration()
    /// The registrations the recorder was asked for, as "scheme path", in order.
    var defaultBrowserCalls: [String] { get }
    /// How often the e2e build's blocked registrar was reached instead of the recorder; it must stay 0.
    var blockedDefaultBrowserCalls: Int { get }
    /// The item as the menu shows it after validation.
    func defaultBrowserItem() throws -> E2EDefaultBrowserItem
    /// Chooses Bow > Set as Default Browser through the app menu in `page`'s window; throws when it is disabled.
    func chooseSetAsDefaultBrowser(in page: any E2EPage) throws
    /// Waits for the registration under way, if any, to end (including its alert being answered).
    func waitForDefaultBrowserRegistration() async
    /// The failure alert up, nil when none.
    func defaultBrowserAlert() -> E2EDefaultBrowserAlert?
    /// Presses OK on the failure alert; throws when none is up.
    func answerDefaultBrowserAlert() throws
}

extension E2ETestApp: E2EDefaultBrowserApp {
    private var command: DefaultBrowserCommand { DefaultBrowserCommand.shared }
    private static var recorder: E2EDefaultBrowserRecorder?

    func installDefaultBrowserRecorder(handler: URL?, failure: NSError?, holds: Bool, besides page: any E2EPage) throws
    {
        try adapter.requireActive(token, "install the default browser recorder")
        let window = try E2EAppAdapter.tabPage(page).controller.window
        let recorder = E2EDefaultBrowserRecorder()
        recorder.handler = handler
        recorder.failure = failure
        recorder.holds = holds
        Self.recorder = recorder
        command.registrar = recorder
        command.alertWindow = { window }
    }

    func removeDefaultBrowserRecorder() {
        Self.recorder?.release()
        Self.recorder = nil
        command.registrar = BlockedDefaultBrowserRegistrar()
        command.alertWindow = { NSApp.keyWindow ?? NSApp.mainWindow }
    }

    func releaseDefaultBrowserRegistration() { Self.recorder?.release() }

    var defaultBrowserCalls: [String] { Self.recorder?.calls ?? [] }

    var blockedDefaultBrowserCalls: Int { BlockedDefaultBrowserRegistrar.calls }

    private func appMenuItem() throws -> NSMenuItem {
        guard
            let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: {
                $0.action == #selector(DefaultBrowserCommand.setAsDefaultBrowser(_:))
            })
        else { throw E2EError("the Bow menu has no default browser item") }
        return item
    }

    func defaultBrowserItem() throws -> E2EDefaultBrowserItem {
        try adapter.requireActive(token, "read the default browser item")
        let item = try appMenuItem()
        item.menu?.update()
        return E2EDefaultBrowserItem(title: item.title, enabled: item.isEnabled)
    }

    func chooseSetAsDefaultBrowser(in page: any E2EPage) throws {
        try adapter.requireActive(token, "choose Bow > Set as Default Browser")
        let title = try defaultBrowserItem().title
        try adapter.chooseMenuItem(path: ["Bow", title], in: page, allowAppTarget: true)
    }

    func waitForDefaultBrowserRegistration() async {
        await command.registration?.value
    }

    func defaultBrowserAlert() -> E2EDefaultBrowserAlert? {
        guard let alert = command.failureAlert else { return nil }
        return E2EDefaultBrowserAlert(
            title: alert.messageText, detail: alert.informativeText, buttons: alert.buttons.map(\.title),
            isAttached: alert.window.sheetParent != nil)
    }

    func answerDefaultBrowserAlert() throws {
        guard let button = command.failureAlert?.buttons.first else { throw E2EError("no default browser alert is up") }
        button.performClick(nil)
    }
}
