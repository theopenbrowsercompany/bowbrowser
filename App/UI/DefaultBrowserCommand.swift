import AppKit
import BowCore

/// What the "Set as Default Browser" item asks of the system, so a test can stand in for it.
@MainActor
protocol DefaultBrowserRegistrar {
    /// The app the system opens links of `scheme` with, nil when none.
    func defaultHandler(forScheme scheme: String) -> URL?
    /// Makes the app at `bundleURL` the handler of `scheme` links. The system asks the person to confirm first, so
    /// this returns when they answer, and throws when they decline or the system refuses.
    func register(bundleURL: URL, scheme: String) async throws
}

#if BOW_E2E
    /// The e2e build's registrar (E2E seam): the real one is not compiled into this build at all, so no e2e run can
    /// reach NSWorkspace's setter, even by a test that forgets to install its recorder. It answers like a system with
    /// no default browser, and counts every registration it is asked for (the harness checks that count stays zero)
    /// and refuses it.
    struct BlockedDefaultBrowserRegistrar: DefaultBrowserRegistrar {
        nonisolated(unsafe) static var calls = 0

        func defaultHandler(forScheme scheme: String) -> URL? { nil }

        func register(bundleURL: URL, scheme: String) async throws {
            Self.calls += 1
            throw CocoaError(.featureUnsupported)
        }
    }
#else
    /// NSWorkspace's own answer and setter. Only Debug and Release builds without the harness contain this type.
    struct SystemDefaultBrowserRegistrar: DefaultBrowserRegistrar {
        func defaultHandler(forScheme scheme: String) -> URL? {
            URL(string: "\(scheme)://example.com").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        }

        func register(bundleURL: URL, scheme: String) async throws {
            try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: scheme)
        }
    }
#endif

/// The app menu's "Set as Default Browser…" item: the target of the item and its validation. The decisions (the
/// schemes, whether Bow already is the default, the titles, what a failure shows) are BowCore's `DefaultBrowser`.
@MainActor
final class DefaultBrowserCommand: NSObject, NSMenuItemValidation {
    static let shared = DefaultBrowserCommand()

    #if BOW_E2E
        var registrar: any DefaultBrowserRegistrar = BlockedDefaultBrowserRegistrar()  // E2E seam
    #else
        var registrar: any DefaultBrowserRegistrar = SystemDefaultBrowserRegistrar()
    #endif
    /// The app the system should register; the running app's bundle.
    var bundleURL = Bundle.main.bundleURL
    /// The window a failure's alert comes up on as a sheet; with none, the alert is app modal.
    var alertWindow: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }
    /// The registration under way, nil when idle. A test waits on it.
    private(set) var registration: Task<Void, Never>?
    /// The failure alert while it is up.
    private(set) var failureAlert: NSAlert?

    private var isDefault: Bool {
        DefaultBrowser.isDefault(
            handler: registrar.defaultHandler(forScheme: DefaultBrowser.probeScheme), bundleURL: bundleURL)
    }

    @objc func setAsDefaultBrowser(_ sender: Any?) {
        guard registration == nil, !isDefault else { return }
        registration = Task { [weak self] in
            await self?.register()
            self?.registration = nil
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(setAsDefaultBrowser(_:)) else { return true }
        let isDefault = isDefault
        item.title = DefaultBrowser.title(isDefault: isDefault)
        return DefaultBrowser.isEnabled(isDefault: isDefault, registering: registration != nil)
    }

    /// Registers each scheme in turn; the first one the person declines or the system refuses ends it.
    private func register() async {
        for scheme in DefaultBrowser.schemes {
            do {
                try await registrar.register(bundleURL: bundleURL, scheme: scheme)
            } catch {
                let nsError = error as NSError
                let failure = DefaultBrowser.Failure(
                    domain: nsError.domain, code: nsError.code, message: nsError.localizedDescription)
                if let text = DefaultBrowser.alert(for: failure, scheme: scheme) {
                    await show(title: text.title, detail: text.detail)
                }
                return
            }
        }
    }

    private func show(title: String, detail: String) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        failureAlert = alert
        defer { failureAlert = nil }
        if let window = alertWindow() {
            await alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
