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
    public var isAudible: Bool
    /// The page is using the camera or the microphone.
    public var isCapturing: Bool
    /// The tab is shown in a window right now.
    public var isVisible: Bool
    /// False when the tab is already unloaded, so there is nothing left to close.
    public var isLoaded: Bool

    public init(
        id: UUID = UUID(), lastActive: Date, isPinnedOrFavorite: Bool = false, isAudible: Bool = false,
        isCapturing: Bool = false, isVisible: Bool = false, isLoaded: Bool = true
    ) {
        self.id = id
        self.lastActive = lastActive
        self.isPinnedOrFavorite = isPinnedOrFavorite
        self.isAudible = isAudible
        self.isCapturing = isCapturing
        self.isVisible = isVisible
        self.isLoaded = isLoaded
    }

    /// Audible, capturing and visible tabs are never unloaded.
    public var isExempt: Bool { isAudible || isCapturing || isVisible }
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
/// The numbers are configuration, so measurements from the hidden tab spike only change `Configuration`.
public struct UnloadPolicy: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// How long a tab may sit idle before it is unloaded, per memory pressure level.
        public var idleLimit: [MemoryPressure: TimeInterval]
        /// How many tabs may stay loaded (exempt ones included), per memory pressure level.
        public var maxLoadedTabs: [MemoryPressure: Int]
        /// Pinned tabs and Favorites get their idle limit multiplied by this.
        public var pinnedIdleMultiplier: Double

        public init(
            idleLimit: [MemoryPressure: TimeInterval], maxLoadedTabs: [MemoryPressure: Int],
            pinnedIdleMultiplier: Double
        ) {
            self.idleLimit = idleLimit
            self.maxLoadedTabs = maxLoadedTabs
            self.pinnedIdleMultiplier = pinnedIdleMultiplier
        }

        /// Placeholder numbers until the hidden tab measurements arrive.
        public static let `default` = Configuration(
            idleLimit: [.normal: 30 * 60, .warning: 10 * 60, .critical: 0],
            maxLoadedTabs: [.normal: 12, .warning: 6, .critical: 1],
            pinnedIdleMultiplier: 3
        )
    }

    public var configuration: Configuration
    private let now: @Sendable () -> Date

    public init(configuration: Configuration = .default, now: @escaping @Sendable () -> Date = { Date() }) {
        self.configuration = configuration
        self.now = now
    }

    /// The tabs to unload now: idle ones first, then over the limit ones, each least recently used first.
    public func decide(tabs: [UnloadTab], pressure: MemoryPressure) -> [UnloadDecision] {
        let current = now()
        let loaded = tabs.filter(\.isLoaded)
        let candidates = loaded.filter { !$0.isExempt }.sorted(by: Self.leastRecentlyUsedFirst)

        var decisions: [UnloadDecision] = []
        var unloaded = Set<UUID>()
        for tab in candidates where idleTime(of: tab, at: current) >= idleLimit(for: tab, pressure: pressure) {
            decisions.append(UnloadDecision(id: tab.id, reason: .idle))
            unloaded.insert(tab.id)
        }

        let limit = max(0, configuration.maxLoadedTabs[pressure] ?? Int.max)
        var remaining = loaded.count - unloaded.count
        for tab in candidates where remaining > limit && !unloaded.contains(tab.id) {
            decisions.append(UnloadDecision(id: tab.id, reason: .overLimit))
            remaining -= 1
        }
        return decisions
    }

    private func idleTime(of tab: UnloadTab, at current: Date) -> TimeInterval {
        max(0, current.timeIntervalSince(tab.lastActive))
    }

    private func idleLimit(for tab: UnloadTab, pressure: MemoryPressure) -> TimeInterval {
        let base = configuration.idleLimit[pressure] ?? .infinity
        // Under critical pressure nothing is held back for being pinned.
        guard tab.isPinnedOrFavorite, pressure < .critical else { return base }
        return base * configuration.pinnedIdleMultiplier
    }

    private static func leastRecentlyUsedFirst(_ a: UnloadTab, _ b: UnloadTab) -> Bool {
        a.lastActive != b.lastActive ? a.lastActive < b.lastActive : a.id.uuidString < b.id.uuidString
    }
}
