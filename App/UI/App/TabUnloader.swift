import AppKit
import BowCore
import Foundation

/// The numbers the unloader runs on, kept in one place so the hidden tabs measurements can tune them.
enum UnloadTuning {
    /// Idle limits and loaded tab limits per memory pressure level. Placeholders until measured.
    static let policy = UnloadPolicy.Configuration.default
    /// How often the unloader looks for idle tabs while it is on. Memory pressure events run a pass at once.
    static let passInterval: TimeInterval = 60
}

/// Unloads tabs the person has not used for a while, or when the Mac runs short of memory, so many open tabs stay
/// cheap (see spec/unload.md). Off unless the `UnloadTabsEnabled` setting is on.
///
/// Each window's `TabUnloadFeature` registers itself and lists the window's loaded tabs. A pass runs `UnloadPolicy`
/// over every window's tabs at once: their last activity from `TabActivityLog` (or when the page loaded, if later),
/// the clock, and the last memory pressure the system reported. While on, a pass runs every
/// `UnloadTuning.passInterval` and on each memory pressure event; turning the setting off, or quitting, stops both.
@MainActor
final class TabUnloader: AppFeature {
    /// The setting that turns unloading on, in `AppSettings.defaults`. Off by default.
    static let enabledKey = "UnloadTabsEnabled"

    private var windows: [WeakWindow] = []
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var quitting = false
    private var defaultsObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    /// Where the unloader reads the time. The e2e harness moves time forward instead of waiting.
    private(set) var clock: any TimeSource = SystemTimeSource()
    /// The memory pressure the system reported last.
    private(set) var pressure: MemoryPressure = .normal
    /// Pages with an unload under way, so a pass never asks one twice.
    private var unloading: Set<TabID> = []

    private struct WeakWindow {
        weak var feature: TabUnloadFeature?
    }

    init(dataDirectory: URL) {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRunning() }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForQuit() }
        }
        updateRunning()
    }

    /// True while the setting is on and the app is not quitting.
    var isEnabled: Bool { !quitting && AppSettings.defaults.bool(forKey: Self.enabledKey) }

    /// True while the pass timer and the memory pressure source are running.
    var isRunning: Bool { timer != nil }

    /// Adds a window's tab list. The unloader holds it weakly, so a closed window drops out on its own.
    func register(_ feature: TabUnloadFeature) {
        windows.removeAll { $0.feature == nil || $0.feature === feature }
        windows.append(WeakWindow(feature: feature))
    }

    /// Stops for good once the app starts quitting: no timer, no memory pressure source, no further passes.
    func stopForQuit() {
        quitting = true
        updateRunning()
    }

    /// Unloads what the policy picks across every window, and returns once each unload has answered, with the pages
    /// that were unloaded. Does nothing while off.
    @discardableResult
    func runPass() async -> [TabID] {
        guard isEnabled else { return [] }
        var candidates: [UUID: (feature: TabUnloadFeature, tab: any EngineTab)] = [:]
        var tabs: [UnloadTab] = []
        for window in windows {
            guard let feature = window.feature else { continue }
            for entry in feature.unloadCandidates() {
                if unloading.contains(entry.tab.tabID) { continue }
                tabs.append(entry.unloadTab)
                candidates[entry.unloadTab.id] = (feature, entry.tab)
            }
        }
        let clock = self.clock
        let policy = UnloadPolicy(configuration: UnloadTuning.policy, now: { clock.now })
        let decisions = policy.decide(tabs: tabs, pressure: pressure)
        // Every unload runs at once, so one page's slow beforeunload handler holds no other back.
        var pending: [(id: TabID, task: Task<Bool, Never>)] = []
        for decision in decisions {
            guard let (feature, tab) = candidates[decision.id], unloading.insert(tab.tabID).inserted else { continue }
            pending.append((tab.tabID, Task { await feature.unload(tab) }))
        }
        var unloaded: [TabID] = []
        for (id, task) in pending {
            if await task.value { unloaded.append(id) }
            unloading.remove(id)
        }
        return unloaded
    }

    /// Starts or stops the timer and the memory pressure source to match the setting.
    private func updateRunning() {
        if isEnabled {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: UnloadTuning.passInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.startPass() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                guard let event = source?.data else { return }
                MainActor.assumeIsolated { self?.memoryPressureChanged(Self.pressure(of: event)) }
            }
            source.resume()
            pressureSource = source
        } else {
            timer?.invalidate()
            timer = nil
            pressureSource?.cancel()
            pressureSource = nil
            pressure = .normal
        }
    }

    private func memoryPressureChanged(_ level: MemoryPressure) {
        pressure = level
        if level > .normal { startPass() }
    }

    private func startPass() {
        Task { await self.runPass() }
    }

    private static func pressure(of event: DispatchSource.MemoryPressureEvent) -> MemoryPressure {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }

    #if BOW_E2E  // E2E seam: the harness moves the clock and reports memory pressure instead of waiting for them.
        /// Replaces the clock with one that moves only when told, starting now, and returns it.
        func e2eUseManualClock() -> ManualTimeSource {
            let manual = ManualTimeSource(Date())
            clock = manual
            return manual
        }

        /// Goes back to the real clock and normal pressure.
        func e2eReset() {
            clock = SystemTimeSource()
            pressure = .normal
        }

        /// Handles `level` as a memory pressure event from the system does, and returns once its pass has ended.
        @discardableResult
        func e2eSimulateMemoryPressure(_ level: MemoryPressure) async -> [TabID] {
            guard isEnabled else { return [] }
            pressure = level
            return await runPass()
        }
    #endif
}
