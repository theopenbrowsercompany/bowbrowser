import AppKit
import BowCore
import Foundation

/// The app's record of when each sidebar tab was last active, kept in `TabActivity.json` beside the sidebar file.
///
/// Windows report through `TabActivityFeature` when a tab is selected or its window becomes key. Saves are debounced
/// (`saveDelay`) and the rest is written when the app quits; entries of tabs no longer in the app's sidebar are
/// dropped at that point.
@MainActor
final class TabActivityLog: AppFeature {
    static let saveDelay: TimeInterval = 1

    private let activity: TabActivity
    private var saveTimer: Timer?
    /// The IDs of every tab still in the app's sidebar, set by the first window that opens. Nil: nothing is pruned.
    private var liveItems: (@MainActor () -> Set<SidebarItemID>?)?

    init(dataDirectory: URL) {
        let url = TabActivity.fileURL(inApplicationSupportFolder: dataDirectory)
        activity = TabActivity(fileURL: url)
        if case .freshAfterSettingAside(let aside, let reason) = activity.openReport {
            let moved = aside.map { " (kept as \($0.lastPathComponent))" } ?? ""
            FileHandle.standardError.write(Data("bow: cannot read \(url.path)\(moved): \(reason)\n".utf8))
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// When `item` was last active, nil if never recorded.
    func lastActive(_ item: SidebarItemID) -> Date? { activity.lastActive(item) }

    /// Marks `item` active now and schedules a save.
    func record(_ item: SidebarItemID) {
        activity.record(item)
        scheduleSave()
    }

    /// Tells the log how to list the tabs that still exist, for pruning at quit. The first caller wins.
    func setLiveItems(_ provider: @escaping @MainActor () -> Set<SidebarItemID>?) {
        if liveItems == nil { liveItems = provider }
    }

    /// Writes any pending change now, after dropping the tabs that no longer exist. Called at quit.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        if let live = liveItems?() { activity.prune(keeping: live) }
        save()
    }

    private func scheduleSave() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveTimer = nil
                self?.save()
            }
        }
    }

    private func save() {
        guard activity.hasUnsavedChanges else { return }
        do {
            try activity.save()
        } catch {
            FileHandle.standardError.write(Data("bow: saving tab activity failed: \(error)\n".utf8))
        }
    }
}
