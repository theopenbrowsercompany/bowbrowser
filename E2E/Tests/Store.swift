import BowCore
import Foundation

/// Tests of the window running on the sidebar store: the sidebar comes back after a relaunch with only its active
/// tab loading, every tab is created in the profile of its Space, and a sidebar file Bow cannot use is told to the
/// person instead of being replaced by a sidebar that is not saved. Fixtures in E2E/Fixtures/store/.
@MainActor
enum StoreTests {
    static let all: [any E2ETest] = [
        StoreRoundtripTest(), LinkProfileTest(), StoreRefusedTest(), StoreNewerFileTest(), StoreSetAsideTest(),
        StoreMissingProfileTest(), StoreWindowSidebarTest(), LinkIgnoredTest(),
    ]

    static func app(_ run: E2ERun) throws -> any E2EStoreApp {
        guard let app = run.app as? any E2EStoreApp else { throw E2EError("the app has no sidebar store to drive") }
        return app
    }

    static func url(_ name: String) -> URL {
        E2EFixture.url("store/page.html?name=\(name)")
    }

    /// A new empty folder of the test's in the run's throwaway data folder, standing in for Bow's data folder.
    static func folder(_ run: E2ERun, _ name: String) throws -> URL {
        let folder = run.dataDirectory.appendingPathComponent("\(run.testName)-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func sidebarFile(in folder: URL) -> URL {
        folder.appendingPathComponent("Sidebar.json")
    }

    static func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The kinds of `notices`, for detail text.
    static func kinds(_ notices: [E2ESidebarNotice]) -> String {
        notices.isEmpty ? "none" : notices.map(\.kind).joined(separator: ",")
    }
}

/// The app's sidebar cannot be opened: its data folder cannot be created, or its file can be neither read nor set
/// aside. No window opens, the person is told why, and asking again opens no window on a temporary sidebar either.
struct StoreRefusedTest: E2ETest {
    let name = "store.refused"
    var checks: [String] { ["store.refused.folder", "store.refused.locked", "store.refused.again"] }

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let windows = try StoreTests.folder(run, "windows")

        // A file where the data folder's parent should be, so the folder cannot be created.
        let parent = try StoreTests.folder(run, "uncreatable")
        let blocker = parent.appendingPathComponent("Bow")
        try Data("not a folder".utf8).write(to: blocker)
        let uncreatable = try await run.step("open with no data folder", timeout: E2ETimeouts.step) {
            try await app.openSavedSidebar(
                inDataFolder: blocker.appendingPathComponent("Data"), windowFolder: windows,
                url: StoreTests.url("refused"), ownSidebar: false)
        }
        let folderKinds = StoreTests.kinds(uncreatable.notices)
        run.check(
            "store.refused.folder", passed: !uncreatable.opened && folderKinds == "cannotOpen",
            "opened=\(uncreatable.opened) notices=\(folderKinds)")

        // An unreadable file in a folder it cannot be moved out of.
        let locked = try StoreTests.folder(run, "locked")
        let file = StoreTests.sidebarFile(in: locked)
        let garbage = Data("this is not a sidebar".utf8)
        try garbage.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let first = try await run.step("open an unreadable locked file", timeout: E2ETimeouts.step) {
            try await app.openSavedSidebar(
                inDataFolder: locked, windowFolder: windows, url: StoreTests.url("refused"), ownSidebar: false)
        }
        let kept = (try? Data(contentsOf: file)) == garbage && StoreTests.contents(of: locked) == ["Sidebar.json"]
        let lockedKinds = StoreTests.kinds(first.notices)
        run.check(
            "store.refused.locked", passed: !first.opened && lockedKinds == "cannotOpen" && kept,
            "opened=\(first.opened) notices=\(lockedKinds) file_kept=\(kept)")

        let again = try await run.step("open it again", timeout: E2ETimeouts.step) {
            try await app.openSavedSidebar(
                inDataFolder: locked, windowFolder: windows, url: StoreTests.url("refused"), ownSidebar: false)
        }
        // A temporary sidebar would have been written in the window folder.
        let temporary = StoreTests.contents(of: windows)
        let againKinds = StoreTests.kinds(again.notices)
        run.check(
            "store.refused.again", passed: !again.opened && againKinds == "cannotOpen" && temporary.isEmpty,
            "opened=\(again.opened) notices=\(againKinds) temporary_files=\(temporary.count)")
    }
}

/// A sidebar file written by a newer Bow is refused with a message naming it, and left exactly where and as it was.
struct StoreNewerFileTest: E2ETest {
    let name = "store.newer_file"

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let folder = try StoreTests.folder(run, "data")
        let file = StoreTests.sidebarFile(in: folder)
        let newer = Data(#"{"version": 999, "items": [], "spaces": []}"#.utf8)
        try newer.write(to: file)
        let windows = try StoreTests.folder(run, "windows")
        let opening = try await run.step("open the newer file", timeout: E2ETimeouts.step) {
            try await app.openSavedSidebar(
                inDataFolder: folder, windowFolder: windows, url: StoreTests.url("newer"), ownSidebar: false)
        }
        let kept = (try? Data(contentsOf: file)) == newer && StoreTests.contents(of: folder) == ["Sidebar.json"]
        let notice = opening.notices.first
        let named = notice?.detail.contains(file.path) == true && notice?.message.contains("newer") == true
        let kinds = StoreTests.kinds(opening.notices)
        run.check(
            name, passed: !opening.opened && kinds == "newerFile" && named && kept,
            "opened=\(opening.opened) notices=\(kinds) names_file=\(named) file_kept=\(kept)")
    }
}

/// An unreadable sidebar file is set aside and a new sidebar starts, and the person is told where the old file went
/// and how to recover it.
struct StoreSetAsideTest: E2ETest {
    let name = "store.set_aside"

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let folder = try StoreTests.folder(run, "data")
        let garbage = Data("this is not a sidebar".utf8)
        try garbage.write(to: StoreTests.sidebarFile(in: folder))
        let windows = try StoreTests.folder(run, "windows")
        let opening = try await run.step("open the unreadable file", timeout: E2ETimeouts.firstLoad) {
            let opening = try await app.openSavedSidebar(
                inDataFolder: folder, windowFolder: windows, url: StoreTests.url("aside"), ownSidebar: false)
            _ = try await opening.page?.waitForLoad(after: 0)
            return opening
        }
        let aside = StoreTests.contents(of: folder).first { $0.hasPrefix("Sidebar.unreadable-") }
        let asidePath = aside.map { folder.appendingPathComponent($0).path }
        let notice = opening.notices.first
        let tellsWhere = asidePath.map { notice?.detail.contains($0) == true } ?? false
        let tellsHow = notice?.detail.contains("rename it back to Sidebar.json") == true
        let kept = asidePath.flatMap { FileManager.default.contents(atPath: $0) } == garbage
        let kinds = StoreTests.kinds(opening.notices)
        run.check(
            name, passed: opening.page != nil && kinds == "setAside" && tellsWhere && tellsHow && kept,
            "opened=\(opening.page != nil) notices=\(kinds) names_file=\(tellsWhere) how=\(tellsHow) kept=\(kept)")
    }
}

/// A saved Space on a profile the engine does not have: the window tells the person instead of opening nothing in
/// silence.
struct StoreMissingProfileTest: E2ETest {
    let name = "store.missing_profile"

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let folder = try StoreTests.folder(run, "data")
        let store = try SidebarStore(fileURL: StoreTests.sidebarFile(in: folder))
        let fresh = store.graph.activeSpaceID
        try store.createSpace(title: "Ghost", profileID: SidebarProfileID("ghost"))
        if let fresh { _ = try store.deleteSpace(fresh) }
        try store.save()
        let windows = try StoreTests.folder(run, "windows")
        let opening = try await run.step("open the sidebar", timeout: E2ETimeouts.step) {
            try await app.openSavedSidebar(
                inDataFolder: folder, windowFolder: windows, url: StoreTests.url("ghost"), ownSidebar: false)
        }
        let notice = opening.notices.first
        let named = notice?.detail.contains("“ghost”") == true && notice?.detail.contains("“Ghost”") == true
        let kinds = StoreTests.kinds(opening.notices)
        run.check(
            name, passed: opening.opened && kinds == "missingProfile" && named,
            "opened=\(opening.opened) notices=\(kinds) names_profile=\(named)")
    }
}

/// A window on a sidebar of its own (an e2e or smoke window) whose sidebar cannot be created: no window opens and
/// the person is told, instead of the app stopping.
struct StoreWindowSidebarTest: E2ETest {
    let name = "store.window_sidebar"

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let parent = try StoreTests.folder(run, "uncreatable")
        let blocker = parent.appendingPathComponent("windows")
        try Data("not a folder".utf8).write(to: blocker)
        let data = try StoreTests.folder(run, "data")
        let opening = try await run.step("open a window on its own sidebar", timeout: E2ETimeouts.step) {
            try await app.openSavedSidebar(
                inDataFolder: data, windowFolder: blocker, url: StoreTests.url("own"), ownSidebar: true)
        }
        let kinds = StoreTests.kinds(opening.notices)
        run.check(
            name, passed: !opening.opened && kinds == "windowSidebar", "opened=\(opening.opened) notices=\(kinds)")
    }
}

/// A link clicked in another app while an e2e run is going is meant for the person's own browser: the run's
/// windows ignore it.
struct LinkIgnoredTest: E2ETest {
    let name = "link.ignored"

    func run(_ run: E2ERun) async throws {
        let app = try StoreTests.app(run)
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: StoreTests.url("window"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let before = try app.sidebarItemCount(of: page)
        let noticesBefore = app.appSidebarNotices.count
        try await run.step("deliver a link", timeout: E2ETimeouts.step) {
            try app.deliverLinkFromOtherApp(StoreTests.url("link"))
            // Anything the link set off would run on the next main thread turns.
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let after = try app.sidebarItemCount(of: page)
        let notices = app.appSidebarNotices.count - noticesBefore
        run.check(
            name, passed: before == after && notices == 0, "items_before=\(before) after=\(after) notices=\(notices)")
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
        let profile = try app.tabProfileID(of: link)
        run.check(name, passed: profile == "work" && cookie == "1", "opened_in=\(profile) cookie=\(cookie)")
    }
}
