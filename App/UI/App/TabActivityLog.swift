import AppKit
import BowCore
import Foundation

/// The app's record of when each sidebar tab was last active, kept in `TabActivity.json` beside the sidebar file.
///
/// Windows report through `TabActivityFeature` when a tab is selected or its window becomes key. Saves are debounced
/// (`saveDelay`) and flushed when the app quits; entries of tabs no longer in the app's sidebar are dropped once, when
/// the first window opens.
@MainActor
final class TabActivityLog: AppFeature {
    static let saveDelay: TimeInterval = 1

    private let activity: TabActivity
    private var saveTimer: Timer?
    private var pruned = false

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

    /// Drops the times of tabs not in `liveItems`. Only the first call does anything: the first window to open is on
    /// the app's own sidebar, which holds every tab that still exists.
    func pruneOnce(keeping liveItems: Set<SidebarItemID>) {
        guard !pruned else { return }
        pruned = true
        activity.prune(keeping: liveItems)
        if activity.hasUnsavedChanges { scheduleSave() }
    }

    /// Writes any pending change now. Called at quit.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
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
