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
        #expect(policy().decide(tabs: [tab(idleMinutes: 5), tab(idleMinutes: 59)], pressure: .normal).isEmpty)
    }

    @Test func unloadsTabsIdleLongerThanTheLimit() {
        let old = tab(idleMinutes: 61)
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
        let pinned = tab(idleMinutes: 61) { $0.isPinnedOrFavorite = true }
        #expect(policy().decide(tabs: [pinned], pressure: .normal).isEmpty)
        let veryOld = tab(idleMinutes: 181) { $0.isPinnedOrFavorite = true }
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

    @Test func defaultNumbersAreTheMeasuredOnes() {
        let configuration = UnloadPolicy.Configuration.default
        #expect(configuration.idleLimit == [.normal: 60 * minute, .warning: 10 * minute, .critical: 0])
        #expect(configuration.maxLoadedTabs == [.normal: Int.max, .warning: 6, .critical: 1])
        #expect(configuration.pinnedIdleMultiplier == 3)
        #expect(configuration.recentlyAudibleWindow == 30)
        #expect(UnloadPolicy.enabledByDefault)
    }

    @Test func normalPressureHasNoCountLimit() {
        let tabs = (0..<30).map { tab(idleMinutes: Double($0)) }
        #expect(policy().decide(tabs: tabs, pressure: .normal).isEmpty)
    }

    @Test func normalPressureUnloadsAfterAnHour() {
        let tabs = (0..<30).map { _ in tab(idleMinutes: 59) }
        #expect(policy().decide(tabs: tabs, pressure: .normal).isEmpty)
        let idle = (0..<29).map { _ in tab(idleMinutes: 61) }
        let shown = tab(idleMinutes: 61) { $0.isVisible = true }
        let decisions = policy().decide(tabs: idle + [shown], pressure: .normal)
        #expect(decisions.count == 29 && decisions.allSatisfy { $0.reason == .idle })
    }

    @Test func warningPressureKeepsSixLoaded() {
        let tabs = (0..<8).map { tab(idleMinutes: Double($0)) }
        let decisions = policy().decide(tabs: tabs, pressure: .warning)
        #expect(decisions == [tabs[7], tabs[6]].map { UnloadDecision(id: $0.id, reason: .overLimit) })
    }

    @Test func criticalPressureKeepsOneLoaded() {
        let tabs = (0..<3).map { tab(idleMinutes: Double($0)) }
        #expect(policy().decide(tabs: tabs, pressure: .critical).count == 3)
    }

    @Test func aTabAudibleWithinThirtySecondsStaysLoaded() {
        let recent = tab(idleMinutes: 500) { $0.lastAudibleAt = now.addingTimeInterval(-29) }
        for pressure in MemoryPressure.allCases {
            #expect(policy().decide(tabs: [recent], pressure: pressure).isEmpty)
        }
    }

    @Test func aTabQuietForThirtySecondsCanUnload() {
        let quiet = tab(idleMinutes: 500) { $0.lastAudibleAt = now.addingTimeInterval(-30) }
        #expect(policy().decide(tabs: [quiet], pressure: .normal).map(\.id) == [quiet.id])
        #expect(policy().decide(tabs: [quiet], pressure: .critical).map(\.id) == [quiet.id])
    }

    @Test func aTabAudibleInTheFutureCountsAsJustAudible() {
        let future = tab(idleMinutes: 500) { $0.lastAudibleAt = now.addingTimeInterval(600) }
        #expect(policy().decide(tabs: [future], pressure: .critical).isEmpty)
    }

    @Test func aRecentlyAudibleTabCountsTowardTheLimit() {
        let recent = tab(idleMinutes: 0) { $0.lastAudibleAt = now.addingTimeInterval(-5) }
        let other = tab(idleMinutes: 1)
        let decisions = policy().decide(tabs: [recent, other], pressure: .critical)
        #expect(decisions.map(\.id) == [other.id])
    }

    @Test func aZeroAudibleWindowSparesOnlyTabsPlayingNow() {
        var configuration = UnloadPolicy.Configuration.default
        configuration.recentlyAudibleWindow = 0
        let stopped = tab(idleMinutes: 500) { $0.lastAudibleAt = now }
        let playing = tab(idleMinutes: 500) { $0.isAudible = true }
        #expect(policy(configuration).decide(tabs: [stopped, playing], pressure: .normal).map(\.id) == [stopped.id])
    }

    @Test func placeholderShowsOnlyForAnUnloadedTabAloneInThePageArea() {
        #expect(UnloadPlaceholder.shows(wasUnloaded: true, paneCount: 1))
        #expect(!UnloadPlaceholder.shows(wasUnloaded: false, paneCount: 1))
        #expect(!UnloadPlaceholder.shows(wasUnloaded: true, paneCount: 2))
    }

    @Test func placeholderEndsWhenThePageLoadsOrCannot() {
        let navigation = EngineNavigation(url: URL(string: "https://example.com")!, isRedirect: false)
        #expect(UnloadPlaceholder.ends(on: .didFinish(navigation, httpStatus: 200)))
        #expect(UnloadPlaceholder.ends(on: .didFail(navigation, NavigationError(code: -105, description: "x"))))
        #expect(UnloadPlaceholder.ends(on: .renderProcessGone(.crashed)))
        #expect(UnloadPlaceholder.ends(on: .closed))
        #expect(UnloadPlaceholder.ends(on: .unloaded))
        #expect(!UnloadPlaceholder.ends(on: .didStartNavigation(navigation)))
        #expect(!UnloadPlaceholder.ends(on: .didCommit(navigation)))
        #expect(!UnloadPlaceholder.ends(on: .didRedirect(navigation)))
    }

    @Test func placeholderTitleFallsBackToTheHostThenTheAddress() {
        let url = URL(string: "https://example.com/a")
        #expect(UnloadPlaceholder.title(saved: "Example", url: url) == "Example")
        #expect(UnloadPlaceholder.title(saved: "  ", url: url) == "example.com")
        #expect(UnloadPlaceholder.title(saved: nil, url: URL(string: "about:blank")) == "about:blank")
        #expect(UnloadPlaceholder.title(saved: nil, url: nil) == "")
    }

    @Test func warningPressureKeepsPinnedTabsForTheLongerLimit() {
        let pinned = tab(idleMinutes: 25) { $0.isPinnedOrFavorite = true }
        #expect(policy().decide(tabs: [pinned], pressure: .warning).isEmpty)
    }

    @Test func aFutureTabIsStillUnloadedUnderCriticalPressure() {
        let future = UnloadTab(lastActive: now.addingTimeInterval(100))
        #expect(policy().decide(tabs: [future], pressure: .critical).count == 1)
    }

    @Test func anEditedFormKeepsAnIdleTabAtNormalAndWarningPressure() {
        let edited = tab(idleMinutes: 24 * 60) { $0.hasEditedForm = true }
        let pinned = tab(idleMinutes: 24 * 60) {
            $0.hasEditedForm = true
            $0.isPinnedOrFavorite = true
        }
        #expect(policy().decide(tabs: [edited, pinned], pressure: .normal).isEmpty)
        #expect(policy().decide(tabs: [edited, pinned], pressure: .warning).isEmpty)
    }

    @Test func anEditedFormIsNotTrimmedToTheLoadedTabLimitAtWarningPressure() {
        // Eight recently used tabs at warning pressure (limit 6): the two least recently used go, skipping the edited one.
        let edited = tab(idleMinutes: 8) { $0.hasEditedForm = true }
        let others = (1...7).map { tab(idleMinutes: Double($0)) }
        let decisions = policy().decide(tabs: [edited] + others, pressure: .warning)
        #expect(decisions.map(\.id) == [others[6].id, others[5].id])
        #expect(decisions.allSatisfy { $0.reason == .overLimit })
    }

    @Test func anEditedFormStillCountsTowardTheLoadedTabLimit() {
        let edited = (1...7).map { minutes in tab(idleMinutes: Double(minutes)) { $0.hasEditedForm = true } }
        let plain = tab(idleMinutes: 0)
        #expect(
            policy().decide(tabs: edited + [plain], pressure: .warning) == [
                UnloadDecision(id: plain.id, reason: .overLimit)
            ])
    }

    @Test func criticalPressureUnloadsAnEditedForm() {
        let edited = tab(idleMinutes: 0) { $0.hasEditedForm = true }
        #expect(policy().decide(tabs: [edited], pressure: .critical) == [UnloadDecision(id: edited.id, reason: .idle)])
    }

    @Test func anEditedFormDoesNotOverrideOtherExemptions() {
        let shown = tab(idleMinutes: 24 * 60) {
            $0.hasEditedForm = true
            $0.isVisible = true
        }
        #expect(policy().decide(tabs: [shown], pressure: .critical).isEmpty)
    }

    @Test func aTabWithoutAnEditedFormStillUnloadsWhenIdle() {
        let plain = tab(idleMinutes: 61)
        let edited = tab(idleMinutes: 61) { $0.hasEditedForm = true }
        #expect(
            policy().decide(tabs: [plain, edited], pressure: .normal) == [UnloadDecision(id: plain.id, reason: .idle)])
    }
}
