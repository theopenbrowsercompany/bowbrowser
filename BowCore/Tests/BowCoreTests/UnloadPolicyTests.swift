import Foundation
import Testing

@testable import BowCore

@Suite struct UnloadPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let minute: TimeInterval = 60

    func policy(_ configuration: UnloadPolicy.Configuration = .default) -> UnloadPolicy {
        let now = self.now
        return UnloadPolicy(configuration: configuration, now: { now })
    }

    func tab(idleMinutes: Double, _ configure: (inout UnloadTab) -> Void = { _ in }) -> UnloadTab {
        var tab = UnloadTab(lastActive: now.addingTimeInterval(-idleMinutes * minute))
        configure(&tab)
        return tab
    }

    @Test func keepsRecentlyUsedTabsAtNormalPressure() {
        #expect(policy().decide(tabs: [tab(idleMinutes: 5), tab(idleMinutes: 29)], pressure: .normal).isEmpty)
    }

    @Test func unloadsTabsIdleLongerThanTheLimit() {
        let old = tab(idleMinutes: 31)
        let decisions = policy().decide(tabs: [tab(idleMinutes: 1), old], pressure: .normal)
        #expect(decisions == [UnloadDecision(id: old.id, reason: .idle)])
    }

    @Test func idleLimitShrinksWithPressure() {
        let tabs = [tab(idleMinutes: 11)]
        #expect(policy().decide(tabs: tabs, pressure: .normal).isEmpty)
        #expect(policy().decide(tabs: tabs, pressure: .warning).count == 1)
    }

    @Test func criticalPressureUnloadsEverythingNotExempt() {
        let tabs = [tab(idleMinutes: 0), tab(idleMinutes: 1) { $0.isPinnedOrFavorite = true }]
        #expect(policy().decide(tabs: tabs, pressure: .critical).count == 2)
    }

    @Test func pinnedTabsAndFavoritesWaitLonger() {
        let pinned = tab(idleMinutes: 31) { $0.isPinnedOrFavorite = true }
        #expect(policy().decide(tabs: [pinned], pressure: .normal).isEmpty)
        let veryOld = tab(idleMinutes: 91) { $0.isPinnedOrFavorite = true }
        #expect(policy().decide(tabs: [veryOld], pressure: .normal).count == 1)
    }

    @Test func neverUnloadsAudibleCapturingOrVisibleTabs() {
        let tabs = [
            tab(idleMinutes: 500) { $0.isAudible = true },
            tab(idleMinutes: 500) { $0.isCapturing = true },
            tab(idleMinutes: 500) { $0.isVisible = true },
        ]
        for pressure in MemoryPressure.allCases {
            #expect(policy().decide(tabs: tabs, pressure: pressure).isEmpty)
        }
    }

    @Test func ignoresTabsThatAreAlreadyUnloaded() {
        let tabs = [tab(idleMinutes: 500) { $0.isLoaded = false }]
        #expect(policy().decide(tabs: tabs, pressure: .critical).isEmpty)
    }

    @Test func overTheLimitUnloadsLeastRecentlyUsedFirst() {
        var configuration = UnloadPolicy.Configuration.default
        configuration.maxLoadedTabs[.normal] = 2
        let tabs = [tab(idleMinutes: 3), tab(idleMinutes: 20), tab(idleMinutes: 10), tab(idleMinutes: 5)]
        let decisions = policy(configuration).decide(tabs: tabs, pressure: .normal)
        #expect(
            decisions == [
                UnloadDecision(id: tabs[1].id, reason: .overLimit),
                UnloadDecision(id: tabs[2].id, reason: .overLimit),
            ])
    }

    @Test func exemptTabsCountTowardTheLimitButStayLoaded() {
        var configuration = UnloadPolicy.Configuration.default
        configuration.maxLoadedTabs[.normal] = 2
        let visible = tab(idleMinutes: 1) { $0.isVisible = true }
        let audible = tab(idleMinutes: 2) { $0.isAudible = true }
        let other = tab(idleMinutes: 3)
        let decisions = policy(configuration).decide(tabs: [visible, audible, other], pressure: .normal)
        #expect(decisions == [UnloadDecision(id: other.id, reason: .overLimit)])
    }

    @Test func idleUnloadsCountTowardTheLimit() {
        var configuration = UnloadPolicy.Configuration.default
        configuration.maxLoadedTabs[.normal] = 2
        let stale = tab(idleMinutes: 60)
        let tabs = [stale, tab(idleMinutes: 1), tab(idleMinutes: 2)]
        let decisions = policy(configuration).decide(tabs: tabs, pressure: .normal)
        #expect(decisions == [UnloadDecision(id: stale.id, reason: .idle)])
    }

    @Test func criticalPressureKeepsOnlyExemptTabs() {
        let visible = tab(idleMinutes: 0) { $0.isVisible = true }
        let other = tab(idleMinutes: 0)
        #expect(policy().decide(tabs: [visible, other], pressure: .critical).map(\.id) == [other.id])
    }

    @Test func ordersTiesByIDForDeterminism() {
        let a = UnloadTab(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, lastActive: .distantPast)
        let b = UnloadTab(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, lastActive: .distantPast)
        let decisions = policy().decide(tabs: [a, b], pressure: .normal)
        #expect(decisions.map(\.id) == [b.id, a.id])
        #expect(policy().decide(tabs: [b, a], pressure: .normal) == decisions)
    }

    @Test func aTabActiveInTheFutureCountsAsNotIdle() {
        let future = UnloadTab(lastActive: now.addingTimeInterval(100))
        #expect(policy().decide(tabs: [future], pressure: .normal).isEmpty)
    }

    @Test func aLevelLeftOutOfTheConfigurationUsesTheNextStricterOne() {
        let configuration = UnloadPolicy.Configuration(
            idleLimit: [.critical: 0], maxLoadedTabs: [.critical: 1], pinnedIdleMultiplier: 1)
        #expect(policy(configuration).decide(tabs: [tab(idleMinutes: 1)], pressure: .normal).count == 1)
    }

    @Test func anEmptyConfigurationNeverUnloads() {
        let configuration = UnloadPolicy.Configuration(idleLimit: [:], maxLoadedTabs: [:], pinnedIdleMultiplier: 1)
        #expect(policy(configuration).decide(tabs: [tab(idleMinutes: 9999)], pressure: .warning).isEmpty)
    }

    @Test func aMultiplierBelowOneDoesNotShortenPinnedTabs() {
        var configuration = UnloadPolicy.Configuration.default
        configuration.pinnedIdleMultiplier = 0
        let pinned = tab(idleMinutes: 29) { $0.isPinnedOrFavorite = true }
        #expect(policy(configuration).decide(tabs: [pinned], pressure: .normal).isEmpty)
    }

    @Test func trimmingToTheLimitUnloadsPinnedTabsLast() {
        var configuration = UnloadPolicy.Configuration.default
        configuration.maxLoadedTabs[.normal] = 1
        let pinned = tab(idleMinutes: 20) { $0.isPinnedOrFavorite = true }
        let plain = tab(idleMinutes: 10)
        let decisions = policy(configuration).decide(tabs: [pinned, plain], pressure: .normal)
        #expect(decisions == [UnloadDecision(id: plain.id, reason: .overLimit)])
    }

    @Test func fourteenRecentTabsWithDefaultLimitsUnloadTheTwoLeastRecentlyUsed() {
        let tabs = (0..<14).map { tab(idleMinutes: Double($0)) }
        let decisions = policy().decide(tabs: tabs, pressure: .normal)
        #expect(decisions.map(\.id) == [tabs[13].id, tabs[12].id])
    }

    @Test func warningPressureKeepsPinnedTabsForTheLongerLimit() {
        let pinned = tab(idleMinutes: 25) { $0.isPinnedOrFavorite = true }
        #expect(policy().decide(tabs: [pinned], pressure: .warning).isEmpty)
    }

    @Test func aFutureTabIsStillUnloadedUnderCriticalPressure() {
        let future = UnloadTab(lastActive: now.addingTimeInterval(100))
        #expect(policy().decide(tabs: [future], pressure: .critical).count == 1)
    }
}
