import Foundation

/// How short of memory the machine is, as reported by the engine or the system.
public enum MemoryPressure: Int, Comparable, CaseIterable, Sendable {
    case normal
    case warning
    case critical

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the unload policy needs to know about one tab. A small value type of its own, so the policy does not depend on the tab model.
public struct UnloadTab: Equatable, Sendable {
    public var id: UUID
    public var lastActive: Date
    /// Pinned tabs and Favorites are kept alive longer when idle, but can still be unloaded.
    public var isPinnedOrFavorite: Bool
    /// The page is playing sound right now.
    public var isAudible: Bool
    /// When the page last stopped playing sound, or nil when it never played any. A tab that went quiet within
    /// `Configuration.recentlyAudibleWindow` still counts as audible.
    public var lastAudibleAt: Date?
    /// The page is using the camera or the microphone.
    public var isCapturing: Bool
    /// The tab is shown in a window right now.
    public var isVisible: Bool
    /// False when the tab is already unloaded, so there is nothing left to close.
    public var isLoaded: Bool
    /// The person edited a form field in the page (typed, pasted, dropped, dictated, autofilled or chose a file) since
    /// it last loaded a new document. Unloading would lose that input, so such a tab is kept at every memory pressure
    /// but critical.
    public var hasEditedForm: Bool
    /// The page is still loading (a navigation is under way). Such a tab is never unloaded.
    public var isLoading: Bool
    /// The person's attention holds the tab: its window is closing or shows a sheet, the app shows a modal panel, or
    /// its page dialog waits for the tab to be shown. An unload would take that away unanswered, so such a tab is
    /// never unloaded (the next pass tries again).
    public var isHeld: Bool
    /// A pinned tab or Favorite showing another page than its saved address. Unloading loses that page unless the
    /// engine restores page state (`UnloadPolicy.EngineAbilities.restoresPageState`).
    public var isBrowsedAwayFromSaved: Bool
    /// The tab's profile has a download under way. Unloading may cancel it unless downloads survive an unload
    /// (`UnloadPolicy.EngineAbilities.downloadsSurviveUnload`).
    public var hasDownloadInProgress: Bool

    public init(
        id: UUID = UUID(), lastActive: Date, isPinnedOrFavorite: Bool = false, isAudible: Bool = false,
        lastAudibleAt: Date? = nil, isCapturing: Bool = false, isVisible: Bool = false, isLoaded: Bool = true,
        hasEditedForm: Bool = false, isLoading: Bool = false, isHeld: Bool = false,
        isBrowsedAwayFromSaved: Bool = false, hasDownloadInProgress: Bool = false
    ) {
        self.hasEditedForm = hasEditedForm
        self.isLoading = isLoading
        self.isHeld = isHeld
        self.isBrowsedAwayFromSaved = isBrowsedAwayFromSaved
        self.hasDownloadInProgress = hasDownloadInProgress
        self.id = id
        self.lastActive = lastActive
        self.isPinnedOrFavorite = isPinnedOrFavorite
        self.isAudible = isAudible
        self.lastAudibleAt = lastAudibleAt
        self.isCapturing = isCapturing
        self.isVisible = isVisible
        self.isLoaded = isLoaded
    }

    /// Audible, capturing and visible tabs are never unloaded (`UnloadPolicy` also spares a tab audible within its
    /// recently audible window).
    public var isExempt: Bool { isAudible || isCapturing || isVisible }

    /// Whether the tab played sound within `window` of `now`: playing now, or stopped less than `window` ago (a stop
    /// in the future, after a clock change, counts as just now).
    public func wasAudible(within window: TimeInterval, of now: Date) -> Bool {
        if isAudible { return true }
        guard let lastAudibleAt else { return false }
        return now.timeIntervalSince(lastAudibleAt) < window
    }
}

/// One tab the policy wants unloaded, and why.
public struct UnloadDecision: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The tab has been idle for longer than the limit at the current memory pressure.
        case idle
        /// More tabs are loaded than the limit at the current memory pressure allows.
        case overLimit
    }

    public var id: UUID
    public var reason: Reason
}

/// Decides which loaded tabs to unload. Pure and deterministic: all inputs, including the clock, are passed in.
/// The numbers are configuration, so measurements only change `Configuration`.
public struct UnloadPolicy: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// How long a tab may sit idle before it is unloaded, per memory pressure level.
        public var idleLimit: [MemoryPressure: TimeInterval]
        /// How many tabs may stay loaded (exempt ones included), per memory pressure level.
        public var maxLoadedTabs: [MemoryPressure: Int]
        /// Pinned tabs and Favorites get their idle limit multiplied by this (values below 1 count as 1).
        public var pinnedIdleMultiplier: Double
        /// How long a tab that stopped playing sound still counts as audible, so it is not unloaded.
        public var recentlyAudibleWindow: TimeInterval

        public init(
            idleLimit: [MemoryPressure: TimeInterval], maxLoadedTabs: [MemoryPressure: Int],
            pinnedIdleMultiplier: Double, recentlyAudibleWindow: TimeInterval = 30
        ) {
            self.idleLimit = idleLimit
            self.maxLoadedTabs = maxLoadedTabs
            self.pinnedIdleMultiplier = pinnedIdleMultiplier
            self.recentlyAudibleWindow = recentlyAudibleWindow
        }

        /// The numbers from the hidden tab measurements (spike S3, spec/unload.md says which are measured and which
        /// judged). A hidden silent tab costs almost no CPU under Chromium's default throttling, so at normal pressure
        /// only a long idle time unloads and there is no count limit (`Int.max`): the cost of a hidden tab is its
        /// memory, which memory pressure reports. Chromium keeps a page unthrottled for 30 seconds after its sound
        /// stops, so that is the recently audible window.
        public static let `default` = Configuration(
            idleLimit: [.normal: 60 * 60, .warning: 10 * 60, .critical: 0],
            maxLoadedTabs: [.normal: Int.max, .warning: 6, .critical: 1],
            pinnedIdleMultiplier: 3,
            recentlyAudibleWindow: 30
        )
    }

    /// What the engine can do around an unload, which decides how many tabs must be kept alive. Both are false for
    /// CEF, which loses a page's state on unload and may cancel a download with the page that started it.
    public struct EngineAbilities: Equatable, Sendable {
        /// An unloaded tab comes back with its history and scroll, so a pinned tab or Favorite browsed away may unload.
        public var restoresPageState: Bool
        /// A download keeps going when the page that started it is unloaded.
        public var downloadsSurviveUnload: Bool

        public init(restoresPageState: Bool = false, downloadsSurviveUnload: Bool = false) {
            self.restoresPageState = restoresPageState
            self.downloadsSurviveUnload = downloadsSurviveUnload
        }
    }

    /// Whether unloading is on when the person has not chosen: on, as Chrome's Memory Saver and Arc are.
    public static let enabledByDefault = true

    public var configuration: Configuration
    public var abilities: EngineAbilities
    private let now: @Sendable () -> Date

    public init(
        configuration: Configuration = .default, abilities: EngineAbilities = EngineAbilities(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.abilities = abilities
        self.now = now
    }

    /// The tabs to unload now: idle ones first, then over the limit ones, each least recently used first.
    public func decide(tabs: [UnloadTab], pressure: MemoryPressure) -> [UnloadDecision] {
        let current = now()
        let loaded = tabs.filter(\.isLoaded)
        let window = max(0, configuration.recentlyAudibleWindow)
        let candidates = loaded.filter {
            !$0.isExempt && !$0.wasAudible(within: window, of: current) && !Self.keepsEditedForm($0, at: pressure)
                && !keepsAlive($0)
        }
        .sorted(by: Self.leastRecentlyUsedFirst)
        // When trimming to the limit, pinned tabs and Favorites go last.
        let trimOrder = candidates.filter { !$0.isPinnedOrFavorite } + candidates.filter(\.isPinnedOrFavorite)

        var decisions: [UnloadDecision] = []
        var unloaded = Set<UUID>()
        for tab in candidates where idleTime(of: tab, at: current) >= idleLimit(for: tab, pressure: pressure) {
            decisions.append(UnloadDecision(id: tab.id, reason: .idle))
            unloaded.insert(tab.id)
        }

        let limit = max(0, Self.value(in: configuration.maxLoadedTabs, for: pressure) ?? Int.max)
        var remaining = loaded.count - unloaded.count
        for tab in trimOrder where remaining > limit && !unloaded.contains(tab.id) {
            decisions.append(UnloadDecision(id: tab.id, reason: .overLimit))
            remaining -= 1
        }
        return decisions
    }

    /// Tabs kept at every memory pressure, critical included, that still count toward the loaded tab limit: one loading,
    /// held by the person's attention, a pinned tab or Favorite browsed away (unless the engine restores page state) or
    /// of a profile with a download under way (unless downloads survive an unload).
    private func keepsAlive(_ tab: UnloadTab) -> Bool {
        tab.isLoading || tab.isHeld
            || (tab.isBrowsedAwayFromSaved && !abilities.restoresPageState)
            || (tab.hasDownloadInProgress && !abilities.downloadsSurviveUnload)
    }

    /// A tab with an edited form is neither unloaded for being idle nor trimmed to the loaded tab limit, except under
    /// critical memory pressure, where it unloads like any other tab: as Chrome's discarding does, since the system
    /// may end the page's process itself when memory runs out, and freeing memory then outweighs the input.
    static func keepsEditedForm(_ tab: UnloadTab, at pressure: MemoryPressure) -> Bool {
        tab.hasEditedForm && pressure < .critical
    }

    private func idleTime(of tab: UnloadTab, at current: Date) -> TimeInterval {
        max(0, current.timeIntervalSince(tab.lastActive))
    }

    private func idleLimit(for tab: UnloadTab, pressure: MemoryPressure) -> TimeInterval {
        let base = Self.value(in: configuration.idleLimit, for: pressure) ?? .infinity
        // Under critical pressure nothing is held back for being pinned.
        guard tab.isPinnedOrFavorite, pressure < .critical else { return base }
        return base * max(1, configuration.pinnedIdleMultiplier.isNaN ? 1 : configuration.pinnedIdleMultiplier)
    }

    /// The setting for a pressure level. A level left out of the configuration uses the nearest stricter level, so a gap
    /// never keeps tabs alive under pressure; with no stricter level it uses the nearest looser one.
    private static func value<T>(in settings: [MemoryPressure: T], for pressure: MemoryPressure) -> T? {
        let stricter = MemoryPressure.allCases.filter { $0 >= pressure }
        let looser = MemoryPressure.allCases.filter { $0 < pressure }.reversed()
        return (stricter + looser).lazy.compactMap { settings[$0] }.first
    }

    private static func leastRecentlyUsedFirst(_ a: UnloadTab, _ b: UnloadTab) -> Bool {
        a.lastActive != b.lastActive ? a.lastActive < b.lastActive : a.id.uuidString < b.id.uuidString
    }
}
