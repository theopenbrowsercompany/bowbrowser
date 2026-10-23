import Foundation

/// Tests of the window running on the sidebar store: the sidebar comes back after a relaunch with only its active
/// tab loading, and every tab is created in the profile of its Space. Fixtures in E2E/Fixtures/store/.
@MainActor
enum StoreTests {
    static let all: [any E2ETest] = [
        StoreRoundtripTest(), LinkProfileTest(),
    ]

    static func app(_ run: E2ERun) throws -> any E2EStoreApp {
        guard let app = run.app as? any E2EStoreApp else { throw E2EError("the app has no sidebar store to drive") }
        return app
    }

    static func url(_ name: String) -> URL {
        E2EFixture.url("store/page.html?name=\(name)")
    }
}

/// Opens twelve tabs in a window, closes the window and opens its sidebar again from the file, as a relaunch does:
/// all twelve come back in the sidebar, and only the active tab loads its page.
struct StoreRoundtripTest: E2ETest {
    let name = "store.roundtrip"
    static let tabCount = 12

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let first = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: StoreTests.url("1"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let items = try await run.step("open tabs", timeout: E2ETimeouts.firstLoad) {
            var opened: [any E2EPage] = []
            for index in 2...Self.tabCount {
                opened.append(try run.app.openTab(at: StoreTests.url("\(index)"), besides: first, select: false))
            }
            // Each tab records its page in the sidebar once it has loaded.
            for page in opened { _ = try await page.waitForLoad(after: 0) }
            return try app.sidebarItemCount(of: first)
        }
        let relaunched = try await run.step("relaunch", timeout: E2ETimeouts.firstLoad) {
            let relaunched = try await app.relaunchSidebar(of: first)
            _ = try await relaunched.page.waitForLoad(after: 0)
            return relaunched
        }
        let title = try await run.step("read the active tab", timeout: E2ETimeouts.step) {
            try await relaunched.page.string("document.title")
        }
        let detail = "items=\(items) after_relaunch=\(relaunched.itemCount)"
        let expected = Self.tabCount
        if items != expected || relaunched.itemCount != expected || relaunched.rowCount != expected {
            run.check(name, passed: false, "\(detail) rows=\(relaunched.rowCount), expected \(expected) each")
        } else if relaunched.loadedTabCount != 1 || title != "1" {
            run.check(name, passed: false, "\(detail) loaded=\(relaunched.loadedTabCount) active=\(title)")
        } else {
            run.check(name, passed: true, detail)
        }
    }
}

/// Opens a window in the test's profile, then one whose Space is on a profile named work, sets a cookie there, and
/// opens a link the way one arrives from another app: it opens in the most recent window, in its Space's profile,
/// and sees the cookie. The profile is fixed when the tab is created.
struct LinkProfileTest: E2ETest {
    let name = "link.profile"

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let work = try await run.step("open windows", timeout: E2ETimeouts.firstLoad) {
            let other = try await run.app.openWindow(at: StoreTests.url("other"))
            _ = try await other.waitForLoad(after: 0)
            let work = try await run.app.openWindow(
                at: StoreTests.url("work"), newProfile: E2EProfile(id: "work", isPersistent: false))
            _ = try await work.waitForLoad(after: 0)
            return work
        }
        try await run.step("set a cookie", timeout: E2ETimeouts.step) {
            _ = try await work.evaluate("document.cookie = 'bow=1; Secure; SameSite=Lax; path=/'")
        }
        let link = try await run.step("open a link", timeout: E2ETimeouts.firstLoad) {
            let link = try app.openExternalLink(StoreTests.url("link"))
            _ = try await link.waitForLoad(after: 0)
            return link
        }
        let cookie = try await run.step("read the cookie", timeout: E2ETimeouts.step) {
            try await link.string("document.cookie.split('; ').includes('bow=1') ? '1' : '0'")
        }
        let profile = try app.profileID(of: link)
        run.check(name, passed: profile == "work" && cookie == "1", "opened_in=\(profile) cookie=\(cookie)")
    }
}
