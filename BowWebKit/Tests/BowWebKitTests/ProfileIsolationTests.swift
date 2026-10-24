import AppKit
import BowCore
import Testing
import WebKit

@testable import BowWebKit

/// One engine on the fixture server, with a sign in route: `/login?user=<name>` sets a lasting `session` cookie, and
/// `/whoami` titles its page `who: <name>` from that cookie, or `who: nobody` without one.
@MainActor
final class EngineRig {
    let server: FixtureServer
    let window: TestWindow
    let engine: WebKitEngine
    let defaultStoreID: UUID
    private(set) var tabs: [WebKitTab] = []
    private(set) var delegates: [TabID: RecordingTabDelegate] = [:]

    init(stores: TestStores) throws {
        server = try FixtureServer.started()
        server.route("/login") { request in
            let user = URLComponents(string: request.target)?.queryItems?.first { $0.name == "user" }?.value ?? "?"
            return .html(
                "<!doctype html><title>signed in</title>",
                headers: ["Set-Cookie: session=\(user); Path=/; Max-Age=600"])
        }
        server.route("/whoami") { request in
            let session = request.cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("session=") }?.dropFirst("session=".count)
            return .html("<!doctype html><title>who: \(session.map(String.init) ?? "nobody")</title>")
        }
        window = try TestHost.window()
        defaultStoreID = stores.track()
        engine = WebKitEngine(
            defaultProfile: ProfileRef(engineID: .default, storeID: self.defaultStoreID, isPersistent: true))
    }

    /// A tab made through `profile`, as the app makes one, loading `path`, with its own recording delegate.
    func tab(in profile: any EngineProfile, _ path: String) -> WebKitTab {
        let tab = profile.createTab(url: server.url(path)) as! WebKitTab
        let delegate = RecordingTabDelegate()
        delegates[tab.tabID] = delegate
        tab.delegate = delegate
        // Test host only: a page in an off screen window counts as occluded, and WebKit throttles it.
        if let webView = tab.webView { WebKitSPI.setWindowOcclusionDetectionEnabled(webView, false) }
        tabs.append(tab)
        return tab
    }

    /// Loads `path` in a new tab of `profile` and returns the title it settles on.
    func title(in profile: any EngineProfile, _ path: String, expecting prefix: String) async throws -> String {
        let tab = tab(in: profile, path)
        return try await waitFor("\(path) in \(profile.profileID) titled \(prefix)...", timeout: 10) {
            let title = tab.state.title
            return !tab.state.isLoading && title.hasPrefix(prefix) ? title : nil
        }
    }

    /// Who `profile` is signed in as, read from a new tab on `/whoami`.
    func whoami(in profile: any EngineProfile) async throws -> String {
        try await title(in: profile, "/whoami", expecting: "who: ")
    }

    /// Signs `profile` in as `user` in a new tab.
    func login(_ user: String, in profile: any EngineProfile) async throws {
        _ = try await title(in: profile, "/login?user=\(user)", expecting: "signed in")
    }

    /// The names and values of the cookies `profile`'s own store holds.
    func cookies(of profile: any EngineProfile) async -> [String] {
        await (profile as! WebKitProfile).store.httpCookieStore.allCookies().map { "\($0.name)=\($0.value)" }
    }

    /// Quits the engine, checks every web view is released, and stops the server and the window.
    func finish() async throws {
        let boxes = tabs.compactMap { $0.webView.map(WeakBox.init) }
        await engine.quit()
        tabs = []
        server.stop()
        TestHost.close(window)
        try await waitUntil("every web view is released", timeout: 5) { boxes.allSatisfy { $0.object == nil } }
    }
}

/// Runs `body` on a fresh engine rig, finishes the rig even when the body throws, lets the engine go, then removes
/// every store `stores` recorded and checks WebKit lists none of them.
@MainActor
func withEngine(_ stores: TestStores, _ body: (EngineRig) async throws -> Void) async throws {
    var failure: (any Error)?
    do {
        let rig = try EngineRig(stores: stores)
        do { try await body(rig) } catch { failure = error }
        do { try await rig.finish() } catch { failure = failure ?? error }
    } catch {
        failure = failure ?? error
    }
    let left = await stores.removeAll()
    #expect(left.isEmpty, "stores still listed: \(left)")
    if let failure { throw failure }
}

/// The engine's profiles: each on its own store, persistent ones by their storage UUID and ephemeral ones in memory,
/// so no two share cookies (W1 criterion 5); and quitting closes every tab.
@Suite(.serialized) @MainActor struct ProfileIsolationTests {
    init() {
        TestHost.start()
    }

    @Test func twoPersistentProfilesKeepCookiesApart() async throws {
        let stores = TestStores()
        let storeA = stores.track()
        let storeB = stores.track()
        try await withEngine(stores) { rig in
            let a = try rig.engine.createProfile(ProfileRef(engineID: "A", storeID: storeA, isPersistent: true))
            let b = try rig.engine.createProfile(ProfileRef(engineID: "B", storeID: storeB, isPersistent: true))
            let storeOfA = (a as! WebKitProfile).store
            let storeOfB = (b as! WebKitProfile).store
            #expect(storeOfA.isPersistent && storeOfA.identifier == storeA)
            #expect(storeOfB.isPersistent && storeOfB.identifier == storeB)
            #expect(storeOfA !== WKWebsiteDataStore.default() && storeOfB !== WKWebsiteDataStore.default())

            try await rig.login("alice", in: a)
            // A's second tab is signed in; B and the default profile are not.
            #expect(try await rig.whoami(in: a) == "who: alice")
            #expect(try await rig.whoami(in: b) == "who: nobody")
            #expect(try await rig.whoami(in: rig.engine.profile(id: .default)!) == "who: nobody")
            // B's store holds none of A's cookies, and its request carried none.
            #expect(await rig.cookies(of: a) == ["session=alice"])
            #expect(await rig.cookies(of: b).isEmpty)
            #expect(await rig.cookies(of: rig.engine.profile(id: .default)!).isEmpty)
            let whoami = rig.server.log().filter { $0.path == "/whoami" }
            #expect(whoami.map(\.cookie) == ["session=alice", "", ""])

            // B signs in as someone else, and A stays alice.
            try await rig.login("bob", in: b)
            #expect(try await rig.whoami(in: b) == "who: bob")
            #expect(try await rig.whoami(in: a) == "who: alice")
            #expect(await rig.cookies(of: a) == ["session=alice"])
            let listed = await WKWebsiteDataStore.allDataStoreIdentifiers
            #expect(listed.contains(storeA) && listed.contains(storeB))
            // The UUID names the data: a store opened on A's UUID, as the next launch opens it, holds A's cookie.
            let names = { (id: UUID) in
                await WKWebsiteDataStore(forIdentifier: id).httpCookieStore.allCookies().map(\.value)
            }
            #expect(await names(storeA) == ["alice"])
            #expect(await names(storeB) == ["bob"])
        }
    }

    @Test func ephemeralProfilesKeepCookiesInMemoryAndApart() async throws {
        let stores = TestStores()
        let storeE = UUID()
        let storeF = UUID()
        try await withEngine(stores) { rig in
            let e = try rig.engine.createProfile(ProfileRef(engineID: "E", storeID: storeE, isPersistent: false))
            let f = try rig.engine.createProfile(ProfileRef(engineID: "F", storeID: storeF, isPersistent: false))
            #expect(!e.isPersistent && !(e as! WebKitProfile).store.isPersistent)
            #expect((e as! WebKitProfile).store !== (f as! WebKitProfile).store)

            try await rig.login("eve", in: e)
            #expect(try await rig.whoami(in: e) == "who: eve")
            #expect(try await rig.whoami(in: f) == "who: nobody")
            #expect(try await rig.whoami(in: rig.engine.profile(id: .default)!) == "who: nobody")
            #expect(await rig.cookies(of: f).isEmpty)
        }
    }

    @Test func createProfileRefusesTakenAndInvalidIDsAndSharedStores() async throws {
        let stores = TestStores()
        try await withEngine(stores) { rig in
            let engine = rig.engine
            let main = try #require(engine.profile(id: .default) as? WebKitProfile)
            #expect(
                main.isPersistent && main.storeID == rig.defaultStoreID && main.store.identifier == rig.defaultStoreID)

            let storeA = stores.track()
            let a = try engine.createProfile(ProfileRef(engineID: "Work", storeID: storeA, isPersistent: true))
            #expect(a.profileID == "Work" && a.isPersistent)
            #expect(engine.profile(id: "Work") === a)
            #expect(engine.profile(id: "Nope") == nil)

            #expect(throws: EngineError.invalidProfileID("a/b")) {
                try engine.createProfile(ProfileRef(engineID: "a/b", storeID: stores.track(), isPersistent: true))
            }
            #expect(throws: EngineError.profileExists("work")) {
                try engine.createProfile(ProfileRef(engineID: "work", storeID: stores.track(), isPersistent: true))
            }
            #expect(throws: EngineError.profileExists("default")) {
                try engine.createProfile(ProfileRef(engineID: "default", storeID: stores.track(), isPersistent: false))
            }
            // Two persistent profiles on one UUID would share a store.
            #expect(throws: EngineError.profileExists("Other")) {
                try engine.createProfile(ProfileRef(engineID: "Other", storeID: storeA, isPersistent: true))
            }
            #expect(throws: EngineError.profileExists("Other")) {
                try engine.createProfile(
                    ProfileRef(engineID: "Other", storeID: rig.defaultStoreID, isPersistent: true))
            }
            // An ephemeral profile uses no store under its UUID, so the UUID shares nothing.
            let e = try engine.createProfile(ProfileRef(engineID: "Other", storeID: storeA, isPersistent: false))
            #expect(!e.isPersistent && (e as! WebKitProfile).store !== (a as! WebKitProfile).store)
            #expect(engine.allProfiles.map(\.profileID) == [.default, "Work", "Other"])
        }
    }

    @Test func quitClosesEveryTabOfEveryProfile() async throws {
        let stores = TestStores()
        try await withEngine(stores) { rig in
            rig.server.route("/slow") { _ in FixtureServer.Response(status: 200, delay: .infinity) }
            let engine = rig.engine
            let a = try engine.createProfile(ProfileRef(engineID: "A", storeID: stores.track(), isPersistent: true))
            let e = try engine.createProfile(ProfileRef(engineID: "E", storeID: UUID(), isPersistent: false))
            let main = engine.profile(id: .default)!
            let loaded = rig.tab(in: main, "/navigation/start.html")
            let slow = rig.tab(in: a, "/slow")
            let other = rig.tab(in: e, "/navigation/a.html")
            let closedEarlier = rig.tab(in: a, "/navigation/b.html")
            try await waitUntil("the pages are under way", timeout: 10) {
                loaded.state.title == "Navigation start" && other.state.title == "A"
                    && rig.delegates[slow.tabID]!.navigation == ["start \(rig.server.url("/slow"))"]
            }
            #expect(await closedEarlier.close())
            let boxes = [loaded, slow, other].compactMap { $0.webView.map(WeakBox.init) }
            #expect(boxes.count == 3)
            // A delegate that answers its tab closing with a new tab, as an app keeping a window's last tab would:
            // quitting closes the new tab too.
            let reopener = rig.tab(in: main, "/navigation/start.html")
            var reopened: WebKitTab?
            let reopening = ReopeningTabDelegate {
                reopened = main.createTab(url: rig.server.url("/navigation/a.html")) as? WebKitTab
            }
            reopener.delegate = reopening

            await engine.quit()
            #expect(reopener.isClosed && reopened != nil && reopened?.isClosed == true && reopened?.webView == nil)
            for tab in [loaded, slow, other, closedEarlier] {
                #expect(tab.isClosed && tab.webView == nil)
                let events = rig.delegates[tab.tabID]!.events
                #expect(events.last == .closed && events.filter { $0 == .closed }.count == 1)
            }
            // The navigation still under way ended aborted before the tab closed.
            #expect(rig.delegates[slow.tabID]!.navigation.last == "fail \(rig.server.url("/slow"))")
            #expect((a as! WebKitProfile).openTabs.isEmpty && (main as! WebKitProfile).openTabs.isEmpty)
            try await waitUntil("every web view is released", timeout: 5) { boxes.allSatisfy { $0.object == nil } }

            // Quitting again closes nothing twice.
            await engine.quit()
            let others = rig.delegates.filter { $0.key != reopener.tabID }.values
            #expect(others.allSatisfy { $0.events.filter { $0 == .closed }.count == 1 })
        }
    }
}

/// A tab delegate that answers the tab's closing by running `onClosed` once.
@MainActor
final class ReopeningTabDelegate: EngineTabDelegate {
    private var onClosed: (() -> Void)?

    init(onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
    }

    func tab(_ tab: any EngineTab, didReceive event: TabEvent) {
        guard event == .closed else { return }
        onClosed?()
        onClosed = nil
    }

    func tab(_ tab: any EngineTab, decidePolicyFor navigation: EngineNavigation) -> NavigationPolicy { .allow }
}
