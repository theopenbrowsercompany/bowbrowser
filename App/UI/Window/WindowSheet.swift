import AppKit

/// One feature's alert sheet on a browser window, shared by the page dialogs and the sign in sheet so both follow the
/// same rules: an `NSAlert` as a sheet on the window, never an app modal panel. While the window already has a sheet
/// (another feature's, or a leave prompt), a new one waits instead of being queued by AppKit where nothing could take
/// it down again, and `retry` offers it again once that sheet ends. Taking a sheet down ends it with `.abort` without
/// calling its `ended` handler, so the feature answers its request once, its own way.
@MainActor
final class WindowSheet<ID: Hashable> {
    private weak var parent: NSWindow?
    /// The sheet that is up and the request it shows.
    private(set) var shown: (id: ID, alert: NSAlert)?
    /// The request that waits for another sheet on the window to end.
    private(set) var waiting: ID?
    /// Called once another sheet on the window has ended, on the next turn, with the request that waited: present it
    /// again if the feature still wants it up.
    var retry: ((ID) -> Void)?
    private var observer: NSObjectProtocol?

    init(parent: NSWindow?) {
        self.parent = parent
        guard let parent else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndSheetNotification, object: parent, queue: .main
        ) { [weak self] _ in
            // On the next turn, once AppKit has let go of the ended sheet.
            Task { @MainActor in self?.retryWaiting() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Shows request `id` as a sheet made by `makeAlert`, and calls `ended` with the button the person pressed. Returns
    /// false when there is no window to show it on (the feature answers the request itself then); returns true when
    /// it is up, or waits for the window's sheet to end (`makeAlert` is not called then).
    func present(
        _ id: ID, makeAlert: () -> NSAlert, ended: @escaping (NSApplication.ModalResponse) -> Void
    ) -> Bool {
        guard let parent else { return false }
        guard parent.attachedSheet == nil else {
            waiting = id
            return true
        }
        if waiting == id { waiting = nil }
        let alert = makeAlert()
        shown = (id, alert)
        alert.beginSheetModal(for: parent) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, let shown = self.shown, shown.id == id, shown.alert === alert else { return }
                self.shown = nil
                ended(response)
            }
        }
        return true
    }

    /// Takes request `id`'s sheet down, or stops it waiting, without calling its `ended` handler.
    func dismiss(_ id: ID) {
        if waiting == id { waiting = nil }
        guard let shown, shown.id == id else { return }
        self.shown = nil
        let sheetWindow = shown.alert.window
        sheetWindow.sheetParent?.endSheet(sheetWindow, returnCode: .abort)
    }

    private func retryWaiting() {
        guard let id = waiting, shown == nil, parent?.attachedSheet == nil else { return }
        waiting = nil
        retry?(id)
    }
}
