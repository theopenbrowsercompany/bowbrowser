import Foundation

/// Tests of links other apps send (GetURL Apple Events): links that arrive before the engine has started are kept
/// and open in order once it has, later links open as they arrive, and each one records the app that sent it.
/// Fixtures in E2E/Fixtures/links/.
@MainActor
enum LinksTests {
    static let all: [any E2ETest] = [LinksIntakeTest()]

    static func address(_ name: String) -> String {
        E2EFixture.url("links/page.html?name=\(name)").absoluteString
    }
}

/// Links delivered before the engine starts (with a sender, without one, and malformed ones) are kept in order and
/// open once the window is open; links delivered after (a batch of them, malformed ones mixed in) open at once. Each
/// opens in a new tab in the Space on screen, in order, with its sender recorded: this app for a sent event, none for
/// an unsent one. A helper process of this app counts as this app.
struct LinksIntakeTest: E2EEarlyLinksTest {
    let name = "links.intake"
    let tags = ["smoke"]
    let checks = ["links.status", "links.intake"]

    var earlyLinks: [E2ELink] {
        [
            E2ELink(address: LinksTests.address("early-1"), sender: true),
            E2ELink(address: "https://", sender: true),
            E2ELink(address: LinksTests.address("early-2"), sender: false),
            E2ELink(address: "mailto:someone@bow.test", sender: false),
            E2ELink(address: LinksTests.address("early-3"), sender: true),
        ]
    }

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2ELinksApp else { throw E2EError("the app takes no links from other apps") }
        let early = app.earlyLinks
        let earlyNames = ["early-1", "early-2", "early-3"]
        let lateLinks =
            [
                E2ELink(address: LinksTests.address("late-1"), sender: true),
                E2ELink(address: "not a link", sender: true),
                E2ELink(address: LinksTests.address("late-2"), sender: false),
            ] + (1...6).map { E2ELink(address: LinksTests.address("batch-\($0)"), sender: $0 % 2 == 1) }
        let lateNames = ["late-1", "late-2"] + (1...6).map { "batch-\($0)" }

        let window = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("links/page.html?name=window"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        try await checkStatusText(run, app: app, page: window)
        let kept = try await run.step("open the kept links", timeout: E2ETimeouts.step) { try app.openKeptLinks() }
        let late = try await run.step("deliver links after start", timeout: E2ETimeouts.step) {
            try app.deliverLinks(lateLinks)
        }
        let opened = kept + late
        let titles = try await run.step("load the links", timeout: E2ETimeouts.firstLoad) {
            var titles: [String] = []
            for link in opened {
                _ = try await link.page.waitForLoad(after: 0)
                titles.append(try await link.page.string("document.title"))
            }
            return titles
        }
        let helper = try await run.step("read a helper's sender", timeout: E2ETimeouts.step) {
            try app.helperLinkSource()
        }

        let expectedNames = earlyNames + lateNames
        let bundle = app.appBundleID
        let senders = opened.map { $0.senderBundleID ?? "none" }
        let expectedSenders = [true, false, true, true, false, true, false, true, false, true, false].map {
            $0 ? bundle : "none"
        }
        let earlyOK =
            early.delivered == earlyLinks.count && early.openedAtOnce == 0
            && early.kept == earlyNames.map(LinksTests.address)
        let openedOK =
            kept.count == earlyNames.count && titles == expectedNames && opened.allSatisfy(\.inSpaceOnScreen)
        let sendersOK =
            !bundle.isEmpty && senders == expectedSenders
            && opened.allSatisfy { ($0.senderBundleID == nil) == ($0.senderProcessID == nil) }
        let helperOK = helper.map { $0.app == bundle && $0.helper != bundle } ?? false
        if earlyOK && openedOK && sendersOK && helperOK {
            run.check(name, passed: true, "early=queued sender=bundle")
        } else {
            let earlyDetail =
                "early delivered=\(early.delivered) kept=\(early.kept.count) opened_at_once=\(early.openedAtOnce)"
            let helperDetail = helper.map { "\($0.helper)->\($0.app ?? "none")" } ?? "none"
            run.check(
                name, passed: false,
                "\(earlyDetail) titles=\(titles) in_space=\(opened.map(\.inSpaceOnScreen)) senders=\(senders) pids=\(opened.map { $0.senderProcessID.map(String.init) ?? "none" }) "
                    + "helper=\(helperDetail)")
        }
    }

    /// links.status: the pointer over a link makes the link's address the tab's status text, reported by the engine
    /// through the tab's UI delegate, and leaving it makes the status empty again.
    private func checkStatusText(_ run: E2ERun, app: any E2ELinksApp, page: any E2EPage) async throws {
        let link = LinksTests.address("hovered")
        let over = try await run.step("hover a link", timeout: E2ETimeouts.step) {
            try await page.movePointer(to: "#status-link")
            return try await E2EWaits.value({ try app.statusText(of: page) }, until: { $0 == link })
        }
        let left = try await run.step("leave the link", timeout: E2ETimeouts.step) {
            try await page.movePointer(to: "h1")
            return try await E2EWaits.value({ try app.statusText(of: page) }, until: { $0.isEmpty })
        }
        run.check(
            "links.status", passed: over == link && left.isEmpty,
            over == link && left.isEmpty ? "over=link left=empty" : "over=\"\(over)\" left=\"\(left)\"")
    }
}
