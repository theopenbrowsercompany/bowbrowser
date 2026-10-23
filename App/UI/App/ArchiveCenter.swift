import AppKit
import BowCore
import Foundation

/// Auto-archive in the running app (spec/auto-archive.md): moves Today tabs nobody used for the profile's threshold
/// out of the sidebar into the archive kept beside the sidebar file, and puts them back on request.
///
/// A pass runs every `passInterval` and when the Mac wakes. It looks at every open browser window, once per sidebar
/// store (two windows on one sidebar share a pass), and runs BowCore's `AutoArchivePolicy` through `ArchiveService`
/// with the last active times from `TabActivityLog`. A Today tab with no recorded time (one restored from the
/// sidebar file and never selected since) is recorded as active when a pass first sees it, since the policy never
/// archives a tab whose idle time is unknown. The tab a window shows and tabs playing sound or using the camera or
/// microphone stay. A store whose window is closing or shows a sheet, or while the app shows a modal panel, is
/// skipped until the next pass, so an archive never takes a tab from under a prompt. Quitting stops the timer.
@MainActor
final class ArchiveCenter: AppFeature {
    /// The per-profile thresholds (`AutoArchiveSettings`, as JSON) in `AppSettings.defaults`.
    static let settingsKey = "AutoArchiveSettings"
    /// How often a pass runs. The shortest threshold is an hour, so a minute late is close enough.
    static let passInterval: TimeInterval = 60

    /// Where auto-archive reads the time. The e2e harness moves time forward instead of waiting.
    private(set) var clock: any TimeSource = SystemTimeSource()
    private var timer: Timer?
    private var quitting = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The archive of each sidebar store a pass or a reopen has used, by store.
    private var archives: [ObjectIdentifier: StoreArchive] = [:]
    /// Windows that have closed. AppKit can keep a closed window in `NSApp.windows` while something still holds it,
    /// and a closed window's controller must never be changed (it would load its tabs again).
    private let closedWindows = NSHashTable<NSWindow>.weakObjects()

    private final class StoreArchive {
        weak var store: SidebarStore?
        /// Nil when the archive file could not be opened (written by a newer Bow, or unreadable and not set aside):
        /// that store never archives this run, and the file is left alone.
        let service: ArchiveService?

        init(store: SidebarStore, service: ArchiveService?) {
            self.store = store
            self.service = service
        }
    }

    init(dataDirectory: URL) {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(
            (
                workspace,
                workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.runPass() }
                }
            ))
        observers.append(
            (
                NotificationCenter.default,
                NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.stopForQuit() }
                }
            ))
        observers.append(
            (
                NotificationCenter.default,
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    let window = notification.object as? NSWindow
                    MainActor.assumeIsolated {
                        if let window { self?.closedWindows.add(window) }
                    }
                }
            ))
        let timer = Timer(timeInterval: Self.passInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.runPass() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// True while the pass timer runs: from launch until the app starts quitting.
    var isRunning: Bool { timer != nil }

    /// The threshold of every profile; one never chosen is `AutoArchiveThreshold.default`.
    var settings: AutoArchiveSettings {
        get {
            guard let data = AppSettings.defaults.data(forKey: Self.settingsKey) else { return AutoArchiveSettings() }
            return (try? JSONDecoder().decode(AutoArchiveSettings.self, from: data)) ?? AutoArchiveSettings()
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            AppSettings.defaults.set(data, forKey: Self.settingsKey)
        }
    }

    /// Stops for good once the app starts quitting: no timer, no further passes.
    func stopForQuit() {
        quitting = true
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    /// Archives every expired Today item of every open window's sidebar, and returns their IDs.
    @discardableResult
    func runPass() -> [SidebarItemID] {
        guard !quitting, !BowEngine.isQuitting else { return [] }
        var archived: [SidebarItemID] = []
        let groups = windowsByStore()
        for windows in groups {
            archived += archive(in: windows)
        }
        // Forget the archives of sidebars no window shows any more (a closed window's own sidebar).
        let live = Set(groups.compactMap { $0.first.map { ObjectIdentifier($0.store) } })
        archives = archives.filter { live.contains($0.key) && $0.value.store != nil }
        return archived
    }

    /// The archive of `store`, opened on first use from the file beside its sidebar file; nil when that file cannot
    /// be opened.
    func archiveService(for store: SidebarStore) -> ArchiveService? {
        let key = ObjectIdentifier(store)
        if let known = archives[key], known.store === store { return known.service }
        let url = Self.archiveURL(besideSidebarFile: store.fileURL)
        var service: ArchiveService?
        do {
            let archive = try ArchiveStore(fileURL: url)
            Self.reportOpening(archive.openReport, url: url)
            service = ArchiveService(sidebar: store, archive: archive, time: clock)
        } catch {
            Self.report(
                "auto-archive is off for \(store.fileURL.lastPathComponent): cannot open \(url.path) (\(error))")
        }
        archives[key] = StoreArchive(store: store, service: service)
        return service
    }

    /// How many damaged records opening `store`'s archive file left out (a copy of the file as it was is kept beside
    /// it); nil when the archive cannot be opened.
    func skippedRecordCount(for store: SidebarStore) -> Int? {
        archiveService(for: store)?.archived.openReport.skippedRecordCount
    }

    /// Puts archived item `id` back where it was in `window`'s sidebar (its Space's Today, or the folder it was in)
    /// and shows it when it is a tab in the Space on screen. Returns whether it is back.
    @discardableResult
    func reopen(_ id: SidebarItemID, in window: BrowserWindowController) -> Bool {
        let store = window.store
        guard !quitting, let service = archiveService(for: store), service.archived.entry(for: id) != nil else {
            return false
        }
        window.changeSidebar { store in
            try service.putBack(id)
            let graph = store.graph
            if graph[id]?.tab != nil, graph.spaceID(containing: id) == graph.activeSpaceID {
                try store.apply([.setActiveTab(id)])
            }
        }
        refreshOthers(sharing: store, besides: window)
        return store.graph[id] != nil
    }

    // MARK: Passes

    /// Runs the policy over the sidebar `windows` share (the first window makes the change, the others follow).
    private func archive(in windows: [BrowserWindowController]) -> [SidebarItemID] {
        guard let first = windows.first, NSApp.modalWindow == nil,
            windows.allSatisfy({ !$0.isClosing && $0.window?.attachedSheet == nil }),
            let service = archiveService(for: first.store)
        else { return [] }
        let graph = first.store.graph
        let activity = first.appFeatures.require(TabActivityLog.self)
        var lastActive: [SidebarItemID: Date] = [:]
        for space in graph.spaces {
            for tab in Self.tabs(under: space.unpinnedContainerID, in: graph) {
                if activity.lastActive(tab) == nil { activity.record(tab) }
                lastActive[tab] = activity.lastActive(tab)
            }
        }
        var keeping: Set<SidebarItemID> = []
        for window in windows {
            if let shown = window.selectedTab, let id = window.modelID(of: shown),
                let item = window.sidebarItemID(for: id)
            {
                keeping.insert(item)
            }
            for row in window.tabList.tabs {
                guard let state = window.engineTab(for: row.id)?.state,
                    state.isAudible || state.isCapturingAudio || state.isCapturingVideo,
                    let item = window.sidebarItemID(for: row.id)
                else { continue }
                keeping.insert(item)
            }
        }
        let settings = settings
        let policy = AutoArchivePolicy(time: clock)
        var archived: [ArchivedEntry] = []
        first.changeSidebar { _ in
            archived = try service.runAutoArchive(
                policy: policy, lastActive: lastActive,
                threshold: { settings.threshold(for: SidebarStores.engineProfileID(of: $0.profileID)) },
                keeping: keeping)
        }
        if !archived.isEmpty { refreshOthers(sharing: first.store, besides: first) }
        return archived.map(\.id)
    }

    /// Brings every other window on `store` up to date after `window` changed it.
    private func refreshOthers(sharing store: SidebarStore, besides window: BrowserWindowController) {
        for other in windowsByStore().flatMap({ $0 }) where other !== window && other.store === store {
            other.changeSidebar { _ in }
        }
    }

    /// The open browser windows, grouped by the sidebar store they show, in window order.
    private func windowsByStore() -> [[BrowserWindowController]] {
        var groups: [[BrowserWindowController]] = []
        let open = NSApp.windows.filter { !closedWindows.contains($0) }
        for case let controller as BrowserWindowController in open.map(\.windowController) {
            if let index = groups.firstIndex(where: { $0[0].store === controller.store }) {
                groups[index].append(controller)
            } else {
                groups.append([controller])
            }
        }
        return groups
    }

    /// Every tab under `id`: in folders and splits too.
    private static func tabs(under id: SidebarItemID, in graph: SidebarGraph) -> [SidebarItemID] {
        guard let item = graph[id] else { return [] }
        if item.tab != nil { return [id] }
        return item.childrenIDs.flatMap { tabs(under: $0, in: graph) }
    }

    // MARK: Files

    /// The archive file of the sidebar at `sidebarFile`: `ArchivedItems.json` beside the app's `Sidebar.json`, and
    /// `<name>.ArchivedItems.json` beside any other sidebar file (a window's own sidebar shares its folder with others).
    static func archiveURL(besideSidebarFile sidebarFile: URL) -> URL {
        let folder = sidebarFile.deletingLastPathComponent()
        if sidebarFile.lastPathComponent == SidebarStore.fileName {
            return ArchiveStore.fileURL(inApplicationSupportFolder: folder)
        }
        let stem = sidebarFile.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent("\(stem).\(ArchiveStore.fileName)", isDirectory: false)
    }

    /// Says on standard error what opening an archive file had to do: set it aside, migrate it, or leave records out.
    private static func reportOpening(_ report: ArchiveStore.OpenReport, url: URL) {
        if case .freshAfterSettingAside(let aside, let reason) = report.origin {
            Self.report(
                "cannot read \(url.path) (\(reason)); it was moved to \(aside.path) and the archive starts empty")
        }
        if report.skippedRecordCount > 0 {
            let copy = report.backupURL.map { "; the file as it was is kept as \($0.path)" } ?? ""
            Self.report("\(url.path): left out \(report.skippedRecordCount) damaged archived item(s)\(copy)")
        }
    }

    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("bow: \(message)\n".utf8))
    }

    #if BOW_E2E  // E2E seam: the harness moves the archive clock forward instead of waiting hours.
        /// Replaces the clock with one that moves only when told, starting now, and returns it.
        func e2eUseManualClock() -> ManualTimeSource {
            let manual = ManualTimeSource(Date())
            clock = manual
            archives = [:]
            return manual
        }

        /// Goes back to the real clock.
        func e2eReset() {
            clock = SystemTimeSource()
            archives = [:]
        }
    #endif
}
