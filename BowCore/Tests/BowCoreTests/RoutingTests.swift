import Foundation
import Testing

@testable import BowCore

private let work = RouteDestination.space(id: "work")
private let personal = RouteDestination.space(id: "personal")

@Suite struct URLPatternTests {
    @Test func containsIgnoresCase() {
        let pattern = URLPattern(.contains, "GitHub.com")
        #expect(pattern.matches("https://github.com/org/repo"))
        #expect(!pattern.matches("https://gitlab.com/org"))
    }

    @Test func containsTreatsTextLiterally() {
        #expect(URLPattern(.contains, "a.c").matches("https://a.c/"))
        #expect(!URLPattern(.contains, "a.c").matches("https://abc/"))
    }

    @Test func matchesIsAnUnanchoredCaseInsensitiveExpression() {
        let pattern = URLPattern(.matches, #"^https://[a-z]+\.example\.com/"#)
        #expect(pattern.matches("HTTPS://Docs.example.com/x"))
        #expect(!pattern.matches("https://example.com/"))
        #expect(URLPattern(.matches, #"example\.com$"#).matches("https://example.com"))
    }

    @Test func unusableTextMatchesNothing() {
        #expect(!URLPattern(.contains, "").matches("https://a.com"))
        #expect(!URLPattern(.matches, "([").matches("(["))
        #expect(URLPattern(.matches, "([").problem != nil)
        #expect(URLPattern(.contains, "").problem != nil)
    }
}

@Suite struct RoutingRuleTests {
    @Test func urlOnlyRuleIgnoresTheSource() {
        let rule = RoutingRule(urlPattern: URLPattern(.contains, "github.com"), destination: work)
        #expect(rule.matches(url: "https://github.com", sourceBundleID: nil))
        #expect(rule.matches(url: "https://github.com", sourceBundleID: "com.apple.mail"))
        #expect(!rule.matches(url: "https://example.com", sourceBundleID: nil))
    }

    @Test func sourceOnlyRuleNeedsThatApp() {
        let rule = RoutingRule(sourceApp: "com.tinyspeck.slackmacgap", destination: personal)
        #expect(rule.matches(url: "https://anything", sourceBundleID: "com.tinyspeck.SlackMacGap"))
        #expect(!rule.matches(url: "https://anything", sourceBundleID: "com.apple.mail"))
        #expect(!rule.matches(url: "https://anything", sourceBundleID: nil))
    }

    @Test func bothConditionsMustHold() {
        let rule = RoutingRule(
            urlPattern: URLPattern(.contains, "docs"), sourceApp: "com.apple.mail", destination: work)
        #expect(rule.matches(url: "https://docs.x", sourceBundleID: "com.apple.mail"))
        #expect(!rule.matches(url: "https://docs.x", sourceBundleID: "com.apple.Safari"))
        #expect(!rule.matches(url: "https://x", sourceBundleID: "com.apple.mail"))
    }

    @Test func unusableRulesNeverMatch() {
        let empty = RoutingRule(destination: work)
        #expect(empty.problem != nil)
        #expect(!empty.matches(url: "https://a", sourceBundleID: nil))
        #expect(RoutingRule(sourceApp: "", destination: work).problem != nil)
        #expect(RoutingRule(urlPattern: URLPattern(.matches, "(["), destination: work).problem != nil)
    }
}

@Suite struct RoutingTableTests {
    private func table() -> RoutingTable {
        RoutingTable(
            rules: [
                RoutingRule(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    urlPattern: URLPattern(.contains, "github.com"), destination: work),
                RoutingRule(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    sourceApp: "com.tinyspeck.slackmacgap", destination: personal),
            ], defaultDestination: .littleArc)
    }

    @Test func routesByUrlBySourceAndByDefault() {
        let table = table()
        #expect(table.route(url: "https://github.com/a").destination == work)
        #expect(
            table.route(url: "https://example.com", sourceBundleID: "com.tinyspeck.slackmacgap").destination
                == personal)
        let fallback = table.route(url: "https://example.com")
        #expect(fallback.destination == .littleArc)
        #expect(fallback.matchedRuleID == nil)
    }

    @Test func firstMatchWinsEvenWhenALaterRuleAlsoMatches() {
        let table = table()
        let decision = table.route(url: "https://github.com", sourceBundleID: "com.tinyspeck.slackmacgap")
        #expect(decision.destination == work)
        #expect(decision.matchedRuleID == table.rules[0].id)
    }

    @Test func noRulesUsesTheDefault() {
        let table = RoutingTable(defaultDestination: .mostRecentWindow)
        #expect(table.route(url: "https://a").destination == .mostRecentWindow)
    }

    @Test func mapsHelperProcessesToTheirParentApp() {
        let helpers = ["com.tinyspeck.slackmacgap.helper": "com.tinyspeck.slackmacgap"]
        let decision = table().route(
            url: "https://example.com", sourceBundleID: "com.tinyspeck.SlackMacGap.Helper", helperParents: helpers)
        #expect(decision.destination == personal)
        #expect(decision.sourceBundleID == "com.tinyspeck.slackmacgap")
    }

    @Test func emptySenderCountsAsNoSource() {
        #expect(table().route(url: "https://example.com", sourceBundleID: "").sourceBundleID == nil)
    }

    @Test func trimsTheAddressBeforeMatching() {
        let table = RoutingTable(
            rules: [RoutingRule(urlPattern: URLPattern(.matches, "^https://a"), destination: work)],
            defaultDestination: personal)
        #expect(table.route(url: "  https://a.com\n").destination == work)
    }

    @Test func skipsUnusableRulesAndReportsThem() {
        let bad = RoutingRule(urlPattern: URLPattern(.matches, "(["), destination: work)
        let table = RoutingTable(rules: [bad], defaultDestination: personal)
        #expect(table.route(url: "([").destination == personal)
        #expect(table.invalidRules.map(\.rule) == [bad.id])
    }

    @Test func reportsShadowedRules() {
        let broad = RoutingRule(urlPattern: URLPattern(.contains, "github.com"), destination: work)
        let narrow = RoutingRule(urlPattern: URLPattern(.contains, "github.com/me"), destination: personal)
        let sourced = RoutingRule(
            urlPattern: URLPattern(.contains, "github.com"), sourceApp: "com.apple.mail", destination: work)
        let table = RoutingTable(rules: [broad, narrow, sourced], defaultDestination: .littleArc)
        #expect(
            table.shadowedRules == [
                ShadowedRule(rule: narrow.id, shadowedBy: broad.id, sameDestination: false),
                ShadowedRule(rule: sourced.id, shadowedBy: broad.id, sameDestination: true),
            ])
    }

    @Test func narrowRuleAboveBroadOneIsNotShadowed() {
        let narrow = RoutingRule(urlPattern: URLPattern(.contains, "github.com/me"), destination: personal)
        let broad = RoutingRule(urlPattern: URLPattern(.contains, "github.com"), destination: work)
        #expect(RoutingTable(rules: [narrow, broad], defaultDestination: .littleArc).shadowedRules.isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let table = RoutingTable(
            rules: [
                RoutingRule(urlPattern: URLPattern(.matches, "x"), sourceApp: "a.b", destination: .profile(id: "p")),
                RoutingRule(sourceApp: "c.d", destination: .mostRecentWindow),
            ], defaultDestination: .littleArc)
        let data = try JSONEncoder().encode(table)
        #expect(try JSONDecoder().decode(RoutingTable.self, from: data) == table)
        #expect(String(decoding: data, as: UTF8.self).contains(#""version":1"#))
    }

    @Test func rejectsANewerVersionAndUnknownDestinations() {
        let newer = #"{"version":2,"rules":[],"defaultDestination":{"kind":"little-arc"}}"#
        #expect(throws: RoutingTable.DecodingFailure.unsupportedVersion(2)) {
            try JSONDecoder().decode(RoutingTable.self, from: Data(newer.utf8))
        }
        let unknown = #"{"version":1,"rules":[],"defaultDestination":{"kind":"teleport"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RoutingTable.self, from: Data(unknown.utf8)) }
    }

    @Test func matchesTheE2eExample() {
        let table = table()
        #expect(table.route(url: "https://github.com/x").destination == work)
        #expect(table.route(url: "https://x.com", sourceBundleID: "com.tinyspeck.slackmacgap").destination == personal)
        #expect(table.route(url: "https://x.com").destination == .littleArc)
    }
}
