import Foundation
import Testing

@testable import BowCore

private let work = RouteDestination.space(id: "work")
private let personal = RouteDestination.profile(id: "personal")
private let slack = "com.tinyspeck.slackmacgap"

@Suite struct RoutingFallbackTests {
    private let github = RoutingRule(urlPattern: URLPattern(.contains, "github.com"), destination: work)
    private let fromSlack = RoutingRule(sourceApp: slack, destination: personal)

    @Test func noSourceFallbackAppliesOnlyToLinksWithoutASourceThatNoRuleMatched() {
        let table = RoutingTable(
            rules: [github, fromSlack], defaultDestination: .littleArc, noSourceDestination: .mostRecentWindow)
        let none = table.route(url: "https://example.com")
        #expect(none.destination == .mostRecentWindow)
        #expect(none.basis == .noSource)
        #expect(none.matchedRuleID == nil)
        // A rule still wins over the fallback.
        #expect(table.route(url: "https://github.com/x").basis == .rule(github.id))
        // A known source that no rule matches goes to the default.
        let mail = table.route(url: "https://example.com", sourceBundleID: "com.apple.mail")
        #expect(mail.destination == .littleArc)
        #expect(mail.basis == .defaultDestination)
    }

    @Test func withoutANoSourceFallbackTheDefaultApplies() {
        let table = RoutingTable(rules: [github], defaultDestination: .littleArc)
        let decision = table.route(url: "https://example.com", sourceBundleID: nil)
        #expect(decision.destination == .littleArc)
        #expect(decision.basis == .defaultDestination)
    }

    @Test func aRuleNamingAGoneDestinationGivesWayToTheDefault() {
        let table = RoutingTable(rules: [github], defaultDestination: .littleArc)
        let decision = table.route(url: "https://github.com", isAvailable: { $0 != work })
        #expect(decision.destination == .littleArc)
        #expect(decision.basis == .defaultDestination)
        #expect(decision.unavailable == work)
    }

    @Test func aGoneDefaultGivesWayToTheMostRecentWindow() {
        let table = RoutingTable(rules: [], defaultDestination: work, noSourceDestination: personal)
        let decision = table.route(url: "https://a.com", isAvailable: { _ in false })
        #expect(decision.destination == .mostRecentWindow)
        #expect(decision.unavailable == personal)
    }

    @Test func noSourceFallbackRoundTripsAndOldFilesReadWithoutIt() throws {
        let table = RoutingTable(rules: [fromSlack], defaultDestination: .littleArc, noSourceDestination: work)
        let data = try JSONEncoder().encode(table)
        #expect(try JSONDecoder().decode(RoutingTable.self, from: data) == table)
        let old = #"{"version":1,"rules":[],"defaultDestination":{"kind":"most-recent-window"}}"#
        let decoded = try JSONDecoder().decode(RoutingTable.self, from: Data(old.utf8))
        #expect(decoded.noSourceDestination == nil)
        #expect(decoded.defaultDestination == .mostRecentWindow)
    }

    @Test func initialTableSendsEverythingToLittleArc() {
        #expect(RoutingTable.initial.rules.isEmpty)
        #expect(RoutingTable.initial.route(url: "https://a.com").destination == .littleArc)
        #expect(RoutingTable.initial.noSourceDestination == nil)
    }
}

@Suite struct LinkRoutingOpeningTests {
    private func decision(_ destination: RouteDestination, _ basis: RoutingDecision.Basis) -> RoutingDecision {
        RoutingDecision(
            destination: destination, matchedRuleID: nil, sourceBundleID: nil, basis: basis)
    }

    @Test func spacesAndProfilesOpenThere() {
        #expect(
            LinkRouting.opening(
                for: decision(.space(id: "s"), .rule(UUID())), littleArcSetting: false, hasBrowserWindow: false)
                == .space("s"))
        #expect(
            LinkRouting.opening(
                for: decision(.profile(id: "p"), .noSource), littleArcSetting: nil, hasBrowserWindow: true)
                == .profile("p"))
        #expect(
            LinkRouting.opening(
                for: decision(.mostRecentWindow, .defaultDestination), littleArcSetting: true,
                hasBrowserWindow: true) == .browserWindow)
    }

    @Test func aDefaultOfLittleArcFollowsTheSetting() {
        let fallback = decision(.littleArc, .defaultDestination)
        #expect(LinkRouting.opening(for: fallback, littleArcSetting: nil, hasBrowserWindow: true) == .littleArc)
        #expect(LinkRouting.opening(for: fallback, littleArcSetting: true, hasBrowserWindow: true) == .littleArc)
        #expect(LinkRouting.opening(for: fallback, littleArcSetting: false, hasBrowserWindow: true) == .browserWindow)
        #expect(LinkRouting.opening(for: fallback, littleArcSetting: true, hasBrowserWindow: false) == .browserWindow)
    }

    @Test func aRuleNamingLittleArcOpensItWhateverTheSetting() {
        for basis in [RoutingDecision.Basis.rule(UUID()), .noSource] {
            let chosen = decision(.littleArc, basis)
            #expect(LinkRouting.opening(for: chosen, littleArcSetting: false, hasBrowserWindow: true) == .littleArc)
            #expect(
                LinkRouting.opening(for: chosen, littleArcSetting: true, hasBrowserWindow: false) == .browserWindow)
        }
    }
}

@Suite struct LinkRoutingSpaceTests {
    private func graph() throws -> SidebarGraph {
        try SidebarGraph.sample().applying([
            .insertSpace("work-a", title: "Work A", profileID: "work"),
            .insertSpace("work-b", title: "Work B", profileID: "Work"),
        ])
    }

    @Test func picksTheSpaceOnScreenWhenItShowsTheProfile() throws {
        var graph = try graph()
        try graph.apply(.setActiveSpace("work-b"))
        #expect(LinkRouting.spaceID(forProfile: "work", in: graph) == "work-b")
    }

    @Test func otherwiseTheFirstSpaceOfTheProfileIgnoringCase() throws {
        var graph = try graph()
        try graph.apply(.setActiveSpace("home"))
        #expect(LinkRouting.spaceID(forProfile: "WORK", in: graph) == "work-a")
        #expect(LinkRouting.spaceID(forProfile: "none", in: graph) == nil)
    }

    @Test func availability() {
        let spaces: Set<String> = ["s1"]
        let profiles: Set<String> = ["Work"]
        #expect(LinkRouting.isAvailable(.space(id: "s1"), spaceIDs: spaces, profileIDs: profiles))
        #expect(!LinkRouting.isAvailable(.space(id: "gone"), spaceIDs: spaces, profileIDs: profiles))
        #expect(LinkRouting.isAvailable(.profile(id: "work"), spaceIDs: spaces, profileIDs: profiles))
        #expect(!LinkRouting.isAvailable(.profile(id: "home"), spaceIDs: spaces, profileIDs: profiles))
        #expect(LinkRouting.isAvailable(.littleArc, spaceIDs: [], profileIDs: []))
        #expect(LinkRouting.isAvailable(.mostRecentWindow, spaceIDs: [], profileIDs: []))
    }
}

@Suite struct LinkRoutingSourceLineTests {
    @Test func namesTheAppAndItsBundleIdentifier() {
        #expect(
            LinkRouting.lastSourceLine(arrived: .init(bundleID: slack, name: "Slack"))
                == "Last link came from: Slack (com.tinyspeck.slackmacgap)")
        #expect(
            LinkRouting.lastSourceLine(arrived: .init(bundleID: slack, name: " "))
                == "Last link came from: com.tinyspeck.slackmacgap")
        #expect(LinkRouting.lastSourceLine(arrived: .init(bundleID: nil, name: "x")).contains("no source app"))
        #expect(LinkRouting.lastSourceLine(arrived: nil).hasPrefix("No link"))
    }
}

@Suite struct RoutingStoreTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func missingFileStartsFromTheInitialTableAndSaves() throws {
        let url = RoutingStore.fileURL(inApplicationSupportFolder: try folder())
        let store = RoutingStore(fileURL: url)
        #expect(store.origin == .freshBecauseMissing)
        #expect(store.table == .initial)
        let table = RoutingTable(
            rules: [RoutingRule(urlPattern: URLPattern(.contains, "github.com"), destination: work)],
            defaultDestination: .mostRecentWindow, noSourceDestination: .littleArc)
        try store.update(table)
        let reopened = RoutingStore(fileURL: url)
        #expect(reopened.origin == .loaded)
        #expect(reopened.table == table)
    }

    @Test func newerFileIsLeftUntouchedAndNeverSavedOver() throws {
        let url = RoutingStore.fileURL(inApplicationSupportFolder: try folder())
        let newer = Data(#"{"version":99,"rules":[],"defaultDestination":{"kind":"little-arc"}}"#.utf8)
        try newer.write(to: url)
        let store = RoutingStore(fileURL: url)
        #expect(store.origin == .newerFile(version: 99))
        #expect(!store.canSave)
        #expect(store.table == .initial)
        #expect(throws: RoutingStore.SaveError.readOnly) {
            try store.update(RoutingTable(defaultDestination: .mostRecentWindow))
        }
        // The new table holds for this run, and the file is as it was.
        #expect(store.table.defaultDestination == .mostRecentWindow)
        #expect(try Data(contentsOf: url) == newer)
    }

    @Test func unreadableFileIsSetAsideAndRoutingStartsOver() throws {
        let folder = try folder()
        let url = RoutingStore.fileURL(inApplicationSupportFolder: folder)
        try Data("not json".utf8).write(to: url)
        let store = RoutingStore(fileURL: url)
        guard case .freshAfterSettingAside(let aside, _) = store.origin else {
            Issue.record("origin \(store.origin)")
            return
        }
        #expect(try Data(contentsOf: aside) == Data("not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.canSave)
        try store.update(.initial)
        #expect(RoutingStore(fileURL: url).origin == .loaded)
    }
}
