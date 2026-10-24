import Foundation

/// Tests of profiles: each has its own storage, and fixture pages load in every profile.
/// Fixtures in E2E/Fixtures/profiles/.
@MainActor
enum ProfilesTests {
    static let all: [any E2ETest] = [
        ProfilesIsolationTest(), ProfilesSpacesTest(), ProfilesMoveSameTest(), ProfilesMoveOtherTest(),
        ProfilesMoveCancelTest(), ProfilesFavoritesRefuseTest(), ProfilesDeleteNextLaunchTest(),
    ]
}

/// Steps the profile move tests share: a seeded window with "Work A" (a move fixture tab M) and "Work B" (a tab B1)
/// on the test's profile, and "Home" (a tab H1) on a profile of its own.
@MainActor
enum E2EProfileMoves {
    @MainActor
    struct Setup {
        let app: any E2EProfilesApp
        let seeder: any E2EStoreSeedApp
        let window: E2ESeededWindow
        let testProfile: String
        let homeProfile: String
        var page: any E2EPage { window.page }
        func space(_ name: String) throws -> String {
            guard let id = window.spaceIDs[name] else { throw E2EError("the seed has no Space \(name)") }
            return id
        }
        /// The Space ID the store files `page`'s tab under now.
        func spaceOf(_ page: any E2EPage) throws -> String {
            try seeder.storeEntry(id: try app.sidebarItemID(of: page), in: window.page)?.spaceID ?? "none"
        }
    }

    static let moveURL = E2EFixture.url("profiles/move.html")

    static func open(_ run: E2ERun, homeIsPersistent: Bool = false) async throws -> Setup {
        guard let app = run.app as? any E2EProfilesApp, let seeder = run.app as? any E2EStoreSeedApp else {
            throw E2EError("the app lacks the profiles or store seed hooks")
        }
        let test = try seeder.testProfileID()
        let home = "\(test)-home"
        let seed = E2ESeed(spaces: [
            E2ESeedSpace("Work A", today: [.tab("M", url: moveURL)]),
            E2ESeedSpace("Work B", today: [.tab("B1", url: E2EFixture.url("profiles/index.html?space=wb"))]),
            E2ESeedSpace(
                "Home", profile: .new(E2EProfile(id: home, isPersistent: homeIsPersistent)),
                today: [.tab("H1", url: E2EFixture.url("profiles/index.html?space=home"))]),
        ])
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await seeder.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        return Setup(app: app, seeder: seeder, window: window, testProfile: test, homeProfile: home)
    }

    /// Types `text` into the move fixture's field on `page`.
    static func type(_ text: String, into page: any E2EPage) async throws {
        try await page.click("#field")
        try await page.type(text)
    }

    /// The field's text and the document's load ID on `page`, as "<text>|<load ID>".
    static func state(of page: any E2EPage) async throws -> String {
        try await page.string("document.querySelector('#field').value + '|' + window.bowLoadID")
    }

    /// The page the window shows once it is a page in profile `id` whose document has loaded, which may be a new
    /// tab the test has not seen.
    static func shown(_ setup: Setup, in id: String) async throws -> any E2EPage {
        let app = setup.app
        let page = try await E2EWaits.value(
            { try app.shownPage(besides: setup.page) },
            until: { page in
                guard let page, !page.isClosed else { return false }
                return (try? app.tabProfileID(of: page)) == id
            })
        guard let page, !page.isClosed, (try? app.tabProfileID(of: page)) == id else {
            let seen = page.flatMap { try? app.tabProfileID(of: $0) } ?? "no page"
            throw E2EError("the window shows no page in profile \(id) (it shows \(seen))")
        }
        // A new tab's first document is a blank one, whose script context goes when the fixture commits.
        while true {
            do {
                let state = try await page.string("location.origin + ' ' + document.readyState")
                if state == "https://bow.test complete" { break }
            } catch let error as CancellationError {
                throw error
            } catch let error as E2EError where error.reason == .testEnded {
                throw error
            } catch {
                // The blank document went away mid question.
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return page
    }

    /// Chooses Move to Space > `space` on `page`'s tab and waits for the question sheet, returning its text.
    static func askToMove(_ setup: Setup, _ page: any E2EPage, to space: String) async throws -> String {
        try setup.app.chooseTabMenuItem(path: ["Move to Space", space], of: page)
        let message = try await E2EWaits.value({ try setup.app.sheetMessage(in: setup.page) }, until: { $0 != nil })
        guard let message else { throw E2EError("moving to \(space) asked nothing") }
        return message
    }
}

/// Moves the fixture tab M, with text typed into its field, from "Work A" to "Work B" (both on the test's profile)
/// with Move to Space: no question, and in Work B it shows the same live page (the same tab, its load ID and text
/// unchanged) in the same profile.
struct ProfilesMoveSameTest: E2ETest {
    let name = "profiles.move_same"

    func run(_ run: E2ERun) async throws {
        let setup = try await E2EProfileMoves.open(run)
        let page = setup.page
        let workB = try setup.space("Work B")
        let before = try await run.step("type into the page", timeout: E2ETimeouts.step) {
            try await E2EProfileMoves.type("kept words", into: page)
            return try await E2EProfileMoves.state(of: page)
        }
        let after = try await run.step("move it to Work B and show it there", timeout: E2ETimeouts.firstLoad) {
            try setup.app.chooseTabMenuItem(path: ["Move to Space", "Work B"], of: page)
            let asked = try setup.app.sheetMessage(in: page)
            let space = try await E2EWaits.value({ try setup.spaceOf(page) }, until: { $0 == workB })
            try setup.app.switchToSpace(workB, besides: page)
            let shown = try await E2EWaits.value(
                { try setup.app.shownPage(besides: page) }, until: { $0 != nil && $0?.isClosed == false })
            let same = shown.map { ($0 as AnyObject) === (page as AnyObject) } ?? false
            return (
                asked: asked, space: space, same: same, closed: page.isClosed,
                profile: try setup.app.tabProfileID(of: page), state: try await E2EProfileMoves.state(of: page)
            )
        }
        let passed =
            after.asked == nil && after.space == workB && after.same && !after.closed
            && after.profile == setup.testProfile && after.state == before && before.hasPrefix("kept words|")
        run.check(
            name, passed: passed,
            "asked=\(after.asked ?? "none") moved=\(after.space == workB) same_tab=\(after.same) "
                + "closed=\(after.closed) profile_kept=\(after.profile == setup.testProfile) "
                + "page_kept=\(after.state == before) text=\(after.state.prefix { $0 != "|" })")
    }
}

/// Moves a fixture tab with typed text from "Work A" (the test's profile) to "Home" (another profile): a sheet asks
/// first, Move closes the page and moves the tab, and in Home the tab loads its address again in Home's profile, as
/// a new document with an empty field.
struct ProfilesMoveOtherTest: E2ETest {
    let name = "profiles.move_other"

    func run(_ run: E2ERun) async throws {
        let setup = try await E2EProfileMoves.open(run)
        let page = setup.page
        let home = try setup.space("Home")
        let item = try setup.app.sidebarItemID(of: page)
        let before = try await run.step("type into the page", timeout: E2ETimeouts.step) {
            try await E2EProfileMoves.type("left behind", into: page)
            return try await E2EProfileMoves.state(of: page)
        }
        let message = try await run.step("Move to Space > Home asks", timeout: E2ETimeouts.step) {
            try await E2EProfileMoves.askToMove(setup, page, to: "Home")
        }
        let moved = try await run.step("answer Move", timeout: E2ETimeouts.firstLoad) {
            try setup.app.answerSheet("Move", text: nil, in: page)
            let closed = try await E2EWaits.value({ page.isClosed }, until: { $0 })
            let space = try await E2EWaits.value(
                { try setup.seeder.storeEntry(id: item, in: page)?.spaceID }, until: { $0 == home })
            return (closed: closed, space: space)
        }
        let reloaded = try await run.step("show it in Home", timeout: E2ETimeouts.firstLoad) {
            try setup.app.switchToSpace(home, besides: page)
            let shown = try await E2EProfileMoves.shown(setup, in: setup.homeProfile)
            return (
                item: try setup.app.sidebarItemID(of: shown), state: try await E2EProfileMoves.state(of: shown),
                url: try await shown.string("location.href")
            )
        }
        let passed =
            message.contains("Home") && moved.closed && moved.space == home && reloaded.item == item
            && reloaded.url == E2EProfileMoves.moveURL.absoluteString && reloaded.state.hasPrefix("|")
            && reloaded.state != before
        run.check(
            name, passed: passed,
            "asked=\(message.contains("Home")) closed=\(moved.closed) moved=\(moved.space == home) "
                + "same_item=\(reloaded.item == item) profile=home url=\(reloaded.url.split(separator: "/").last ?? "") "
                + "text=\(reloaded.state.prefix { $0 != "|" }.isEmpty ? "empty" : "kept") "
                + "new_document=\(reloaded.state != before)")
    }
}

/// Asks to move a tab to "Home" (another profile) and answers Cancel: the tab stays in "Work A" with its live page.
/// Asking again asks again (there is no "don't ask again"); a draft that asks before leaving, answered Stay at its
/// leave prompt after Move, also stays where it was with its page.
struct ProfilesMoveCancelTest: E2ETest {
    let name = "profiles.move_cancel"
    let checks = ["profiles.move_cancel", "profiles.move_stay"]

    func run(_ run: E2ERun) async throws {
        let setup = try await E2EProfileMoves.open(run)
        let page = setup.page
        let workA = try setup.space("Work A")
        let before = try await run.step("type into the page", timeout: E2ETimeouts.step) {
            try await E2EProfileMoves.type("still here", into: page)
            return try await E2EProfileMoves.state(of: page)
        }
        let cancelled = try await run.step("ask twice and answer Cancel", timeout: E2ETimeouts.step) {
            var asked = 0
            for _ in 0..<2 {
                _ = try await E2EProfileMoves.askToMove(setup, page, to: "Home")
                asked += 1
                try setup.app.answerSheet("Cancel", text: nil, in: page)
                _ = try await E2EWaits.value({ try setup.app.sheetMessage(in: page) }, until: { $0 == nil })
            }
            return (asked: asked, space: try setup.spaceOf(page), closed: page.isClosed)
        }
        let after = try await E2EProfileMoves.state(of: page)
        run.check(
            name,
            passed: cancelled.asked == 2 && cancelled.space == workA && !cancelled.closed && after == before,
            "asked=\(cancelled.asked) stayed=\(cancelled.space == workA) closed=\(cancelled.closed) "
                + "page_kept=\(after == before)")

        let stayed = try await run.step("answer Move, then Stay at the leave prompt", timeout: E2ETimeouts.firstLoad) {
            let draft = try setup.app.openTab(at: E2EFixture.url("tabs/leave.html"), besides: page, select: true)
            _ = try await draft.waitForLoad(after: 0)
            try await draft.click("textarea")
            try await draft.type("unsaved words")
            draft.leavePromptAnswer = false
            _ = try await E2EProfileMoves.askToMove(setup, draft, to: "Home")
            try setup.app.answerSheet("Move", text: nil, in: page)
            let prompts = try await E2EWaits.value({ draft.leavePrompts }, until: { $0 >= 1 })
            // The page runs script again once its prompt is over and the close it answered was refused.
            let text = try await draft.string("document.querySelector('textarea').value")
            return (prompts: prompts, text: text, space: try setup.spaceOf(draft), closed: draft.isClosed)
        }
        run.check(
            "profiles.move_stay",
            passed: stayed.prompts == 1 && stayed.text == "unsaved words" && stayed.space == workA && !stayed.closed,
            "prompts=\(stayed.prompts) stayed=\(stayed.space == workA) closed=\(stayed.closed) "
                + "draft=\(stayed.text == "unsaved words" ? "kept" : stayed.text)")
    }
}

/// Favorites refuse a tab of another profile: dropping Home's tab H1 (another profile) on the Favorites grid of
/// "Work A" (the test's profile) is refused and H1 stays in Home, while Work B's tab B1 (same profile) goes in.
struct ProfilesFavoritesRefuseTest: E2ETest {
    let name = "profiles.favorites_refuse"

    func run(_ run: E2ERun) async throws {
        let setup = try await E2EProfileMoves.open(run)
        let page = setup.page
        guard let h1 = setup.window.itemIDs["H1"], let b1 = setup.window.itemIDs["B1"] else {
            throw E2EError("the seed has no H1 or B1")
        }
        let home = try setup.space("Home")
        let result = try await run.step("drop H1, then B1, on Work A's Favorites", timeout: E2ETimeouts.step) {
            let other = try setup.app.dropOnFavoritesGrid(item: h1, in: page)
            let otherEntry = try setup.seeder.storeEntry(id: h1, in: page)
            let same = try setup.app.dropOnFavoritesGrid(item: b1, in: page)
            let sameEntry = try setup.seeder.storeEntry(id: b1, in: page)
            return (other: other, otherSpace: otherEntry?.spaceID, same: same, sameSpace: sameEntry?.spaceID)
        }
        let passed = !result.other && result.otherSpace == home && result.same && result.sameSpace == nil
        run.check(
            name, passed: passed,
            "other_profile=\(result.other ? "taken" : "refused") stays_in_home=\(result.otherSpace == home) "
                + "same_profile=\(result.same ? "taken" : "refused") favorite=\(result.sameSpace == nil)")
    }
}

/// Deletes a profile from the Space menu: with "Used" (the Space's profile now) and "Old" (no Space) registered,
/// Profile > Delete Profile… enables only Old; deleting it asks in a sheet, takes it out of the list and leaves its
/// folder on disk, and the launch step then removes the folder while Used's stays. First it checks that the storage
/// UUIDs the registry gave at open were saved to Profiles.json before any profile change.
struct ProfilesDeleteNextLaunchTest: E2ETest {
    let name = "profiles.delete_next_launch"
    let checks = ["profiles.store_ids", "profiles.delete_next_launch"]

    func run(_ run: E2ERun) async throws {
        let setup = try await E2EProfileMoves.open(run)
        let app = setup.app
        let page = setup.page
        let names = (old: "\(setup.testProfile) Old", used: "\(setup.testProfile) Used")
        // Before this test changes a profile: the storage UUIDs the registry gave at open are already on disk.
        let heldIDs = try app.registeredStoreIDs()
        let savedIDs = Self.storedStoreIDs(in: run.dataDirectory)
        run.check(
            "profiles.store_ids", passed: !heldIDs.isEmpty && savedIDs == heldIDs,
            "held=\(heldIDs.count) saved=\(savedIDs.count) same=\(savedIDs == heldIDs)")
        let ids = try await run.step("register Old and Used, put Work A on Used", timeout: E2ETimeouts.firstLoad) {
            let old = try app.createRegisteredProfile(named: names.old)
            let used = try app.createRegisteredProfile(named: names.used)
            try app.chooseSpaceMenuItem(["Profile", names.used], in: page)
            _ = try await E2EProfileMoves.shown(setup, in: used)
            return (old: old, used: used)
        }
        let fileManager = FileManager.default
        let oldFolder = run.dataDirectory.appendingPathComponent("Profile-\(ids.old)", isDirectory: true)
        let usedFolder = run.dataDirectory.appendingPathComponent("Profile-\(ids.used)", isDirectory: true)
        // Old's storage as an earlier run would have left it.
        try fileManager.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data("cookie".utf8).write(to: oldFolder.appendingPathComponent("Cookies"))

        let menu = try app.spaceSubmenuTitles(["Profile", "Delete Profile\u{2026}"], in: page)
        let deleted = try await run.step("Delete Profile… > Old and confirm", timeout: E2ETimeouts.step) {
            try app.chooseSpaceMenuItem(["Profile", "Delete Profile\u{2026}", names.old], in: page)
            let message = try await E2EWaits.value({ try app.sheetMessage(in: page) }, until: { $0 != nil })
            try app.answerSheet("Delete Profile", text: nil, in: page)
            let listed = try await E2EWaits.value(
                { try app.registeredProfiles() }, until: { !$0.contains("\(ids.old):\(names.old)") })
            return (message: message ?? "", listed: listed)
        }
        let kept = fileManager.fileExists(atPath: oldFolder.path)
        let outcomes = try app.deleteMarkedProfileFolders()
        let gone = !fileManager.fileExists(atPath: oldFolder.path)
        let usedKept = fileManager.fileExists(atPath: usedFolder.path)
        let passed =
            menu.contains(names.old) && menu.contains("\(names.used)!") && deleted.message.contains(names.old)
            && !deleted.listed.contains("\(ids.old):\(names.old)")
            && deleted.listed.contains("\(ids.used):\(names.used)")
            && kept && gone && usedKept
        run.check(
            name, passed: passed,
            "menu_old=\(menu.contains(names.old) ? "enabled" : "missing") "
                + "menu_used=\(menu.contains("\(names.used)!") ? "disabled" : "enabled") "
                + "unlisted=\(!deleted.listed.contains("\(ids.old):\(names.old)")) before_launch=\(kept ? "kept" : "gone") "
                + "after_launch=\(gone ? "gone" : "kept") used=\(usedKept ? "kept" : "gone") outcomes=\(outcomes)")
    }

    /// Profiles.json's storage UUID text by profile ID, as the file in `folder` holds them; empty when it is missing.
    static func storedStoreIDs(in folder: URL) -> [String: String] {
        let url = folder.appendingPathComponent("Profiles.json")
        guard let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var ids: [String: String] = [:]
        for profile in object["profiles"] as? [[String: Any]] ?? [] {
            if let id = profile["id"] as? String, let storeID = profile["storeID"] as? String { ids[id] = storeID }
        }
        return ids
    }
}

/// Opens windows in the default profile, a new in-memory profile and a new persistent profile, checks that the
/// fixture page loads in each, that site storage written in one is not seen in the others, and that a taken
/// profile ID is refused.
struct ProfilesIsolationTest: E2ETest {
    let name = "profiles.isolation"
    let tags = ["smoke"]
    let checks = ["profiles.fixtures", "profiles.storage", "profiles.isolation", "profiles.taken"]

    func run(_ run: E2ERun) async throws {
        let url = E2EFixture.url("profiles/index.html")
        let pages = try await run.step("open windows", timeout: E2ETimeouts.step) {
            [
                try await run.app.openWindow(at: url, profile: .appDefault),
                try await run.app.openWindow(at: url, newProfile: E2EProfile(id: "e2e-memory", isPersistent: false)),
                try await run.app.openWindow(at: url, newProfile: E2EProfile(id: "e2e-disk", isPersistent: true)),
            ]
        }
        try await run.step("load in every profile", timeout: E2ETimeouts.firstLoad) {
            for page in pages {
                let status = try await page.waitForLoad(after: 0)
                guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
            }
        }
        run.check("profiles.fixtures", passed: true, "profiles=\(pages.count)")

        // A persistent profile keeps its data in its own folder in the root; an in-memory one has none.
        let fileManager = FileManager.default
        let diskFolder = run.dataDirectory.appendingPathComponent("Profile-e2e-disk").path
        let memoryFolder = run.dataDirectory.appendingPathComponent("Profile-e2e-memory").path
        let onDisk = fileManager.fileExists(atPath: diskFolder) && !fileManager.fileExists(atPath: memoryFolder)
        run.check(
            "profiles.storage",
            passed: onDisk,
            onDisk ? "persistent=Profile-e2e-disk memory=none" : "folders: \(diskFolder) and \(memoryFolder)"
        )

        try await run.step("write storage", timeout: E2ETimeouts.step) {
            for (index, page) in pages.enumerated() {
                _ = try await page.evaluate("localStorage.setItem('owner', 'profile\(index)')")
            }
        }
        try await run.step("read storage", timeout: E2ETimeouts.step) {
            var owners: [String] = []
            for page in pages {
                owners.append(try await page.string("localStorage.getItem('owner') ?? 'none'"))
            }
            let expected = pages.indices.map { "profile\($0)" }
            run.check(name, passed: owners == expected, "owners=\(owners.joined(separator: ","))")
        }

        try await run.step("refuse a taken ID", timeout: E2ETimeouts.step) {
            // Only a refusal because the ID is taken counts; any other error (a window that would show, a missing
            // tab) fails the check with its reason.
            var refused: [String] = []
            var problems: [String] = []
            for id in ["Default", "e2e-memory", "E2E-DISK"] {
                do {
                    _ = try await run.app.openWindow(at: url, newProfile: E2EProfile(id: id, isPersistent: false))
                    problems.append("\(id) was accepted")
                } catch let error as E2EError where error.reason == .profileTaken {
                    refused.append(id)
                } catch let error as CancellationError {
                    // A timed-out step is cancelled; stop here instead of opening the next window.
                    throw error
                } catch let error as E2EError where error.reason == .testEnded {
                    throw error
                } catch {
                    problems.append("\(id) failed for another reason: \(error)")
                }
            }
            run.check(
                "profiles.taken", passed: problems.isEmpty,
                problems.isEmpty ? "refused=\(refused.joined(separator: ","))" : problems.joined(separator: "; "))
        }
    }
}

/// Puts Spaces on profiles from the Space menu, the way a person does: in a seeded window with Spaces "Work A" (a
/// fixture tab and a draft that asks before leaving), "Work B" and "Personal" (a fixture tab each), all on the test's
/// profile. "Profile > New Profile…" named Work, answered Stay at the draft's leave prompt, keeps Work A on its
/// profile; then "Profile > Work" closes Work A's pages and loads the active one again in Work (its folder directly in
/// the data folder), and the menu checks Work. Work B chooses Work too and Personal a new profile Personal, each tab
/// loading again there. A cookie set in Work A is seen in Work B and not in Personal. The renderer processes counted
/// after each of the three are in the detail, for the question whether Spaces of one profile share them.
struct ProfilesSpacesTest: E2ETest {
    let name = "profiles"
    let checks = ["profiles.spaces", "profiles"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EProfilesApp, let seeder = run.app as? any E2EStoreSeedApp else {
            throw E2EError("the app lacks the profiles or store seed hooks")
        }
        let url = { (name: String) in E2EFixture.url("profiles/index.html?space=\(name)") }
        let testProfile = try seeder.testProfileID()
        // Named after the test, so the profile ID it gets is not one another test gives the engine.
        let workName = "\(testProfile) Work"
        let seed = E2ESeed(spaces: [
            E2ESeedSpace("Work A", today: [.tab("WA", url: url("wa"))]),
            E2ESeedSpace("Work B", today: [.tab("WB", url: url("wb"))]),
            E2ESeedSpace("Personal", today: [.tab("P", url: url("personal"))]),
        ])
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await seeder.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let first = window.page
        guard let workA = window.spaceIDs["Work A"], let workB = window.spaceIDs["Work B"],
            let personal = window.spaceIDs["Personal"]
        else { throw E2EError("the seed has no Space IDs") }
        func profile(of space: String) throws -> String {
            try seeder.storeEntry(id: space, in: first)?.profileID ?? "none"
        }
        func until<T>(_ read: () throws -> T, _ condition: (T) -> Bool) async throws -> T {
            // Only the step's own limit ends the wait (E2EWaits gives up shortly before it with what it saw last).
            try await E2EWaits.value(read, until: condition)
        }
        /// The page the window shows once it is a page in profile `id` that has loaded.
        func shown(in id: String) async throws -> any E2EPage {
            let page = try await until(
                { try app.shownPage(besides: first) },
                { page in
                    guard let page, !page.isClosed else { return false }
                    return (try? app.tabProfileID(of: page)) == id
                })
            // The wait gives up near the step's limit with what it saw last, so a slow profile fails here by name.
            guard let page, !page.isClosed, (try? app.tabProfileID(of: page)) == id else {
                let seen = page.flatMap { try? app.tabProfileID(of: $0) } ?? "no page"
                throw E2EError("the window shows no page in profile \(id) (it shows \(seen))")
            }
            // The new tab's first document is a blank one, whose script context goes when the fixture commits, so
            // ask again until the fixture itself has loaded; the step's limit ends a page that never does.
            while true {
                do {
                    let state = try await page.string("location.origin + ' ' + document.readyState")
                    if state == "https://bow.test complete" { break }
                } catch let error as CancellationError {
                    throw error
                } catch let error as E2EError where error.reason == .testEnded {
                    throw error
                } catch {
                    // The blank document went away mid question.
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return page
        }

        let draft = try await run.step("open a draft and answer Stay to New Profile", timeout: E2ETimeouts.firstLoad) {
            let draft = try app.openTab(at: E2EFixture.url("tabs/leave.html"), besides: first, select: true)
            _ = try await draft.waitForLoad(after: 0)
            // Chromium asks before leaving only a page the person has interacted with.
            try await draft.click("textarea")
            try await draft.type("unsaved words")
            draft.leavePromptAnswer = false
            try app.chooseSpaceMenuItem(["Profile", "New Profile\u{2026}"], in: first)
            guard try await until({ try app.sheetMessage(in: first) }, { $0 != nil }) != nil else {
                throw E2EError("New Profile showed no sheet")
            }
            try app.answerSheet("Create Profile", text: workName, in: first)
            let prompts = try await until({ draft.leavePrompts }, { $0 >= 1 })
            guard prompts >= 1 else { throw E2EError("the draft never asked before leaving") }
            // The page runs script again once its prompt is over and the close it answered was refused.
            _ = try await draft.evaluate("document.querySelector('textarea').value")
            return draft
        }
        let stayed = (profile: try profile(of: workA), open: !draft.isClosed, prompts: draft.leavePrompts)
        let workID = try app.registeredProfiles().first { $0.hasSuffix(":\(workName)") }.map {
            String($0.prefix { $0 != ":" })
        }
        guard let workID else { throw E2EError("New Profile registered no Work: \(try app.registeredProfiles())") }

        let work = try await run.step("choose Profile > Work", timeout: E2ETimeouts.firstLoad) {
            draft.leavePromptAnswer = true
            try app.chooseSpaceMenuItem(["Profile", workName], in: first)
            let page = try await shown(in: workID)
            let closed = try await until({ (first: first.isClosed, draft: draft.isClosed) }, { $0.first && $0.draft })
            guard closed.first && closed.draft else {
                throw E2EError(
                    "Work A's pages did not close (first closed: \(closed.first), draft closed: \(closed.draft))")
            }
            return page
        }
        let menu = try app.spaceMenuTitles(in: first)
        let folder = run.dataDirectory.appendingPathComponent("Profile-\(workID)", isDirectory: true)
        let workCookies = try await run.step("set a cookie in Work A", timeout: E2ETimeouts.step) {
            _ = try await work.evaluate("document.cookie = 'who=work; path=/; Secure; SameSite=Lax; max-age=3600'")
            let count = try await work.evaluate("document.cookie.split('; ').filter(c => c === 'who=work').length")
            return count as? Int ?? -1
        }
        let renderersOne = try app.rendererProcessCount()

        let shared = try await run.step("put Work B on Work and read the cookie", timeout: E2ETimeouts.firstLoad) {
            try app.switchToSpace(workB, besides: first)
            _ = try await shown(in: testProfile)
            try app.chooseSpaceMenuItem(["Profile", workName], in: first)
            let page = try await shown(in: workID)
            return (page: page, cookie: try await page.string("document.cookie || 'none'"))
        }
        let renderersTwo = try app.rendererProcessCount()

        let other = try await run.step(
            "put Personal on a new profile and read the cookie", timeout: E2ETimeouts.firstLoad
        ) {
            try app.switchToSpace(personal, besides: first)
            _ = try await shown(in: testProfile)
            try app.chooseSpaceMenuItem(["Profile", "New Profile\u{2026}"], in: first)
            guard try await until({ try app.sheetMessage(in: first) }, { $0 != nil }) != nil else {
                throw E2EError("New Profile showed no sheet")
            }
            try app.answerSheet("Create Profile", text: "\(testProfile) Personal", in: first)
            let id = try await until({ try profile(of: personal) }, { $0 != testProfile && $0 != workID })
            let page = try await shown(in: id)
            return (page: page, cookie: try await page.string("document.cookie || 'none'"), id: id)
        }
        let renderersThree = try app.rendererProcessCount()

        let sharedProfile = try app.tabProfileID(of: shared.page)
        let otherProfile = try app.tabProfileID(of: other.page)
        let spacesPassed =
            stayed.profile == testProfile && stayed.open && stayed.prompts == 1
            && menu.contains("Profile/Default") && menu.contains("Profile/\(workName)*")
            && menu.contains("Profile/New Profile\u{2026}")
            && FileManager.default.fileExists(atPath: folder.path)
            && sharedProfile == workID && otherProfile == other.id
        run.check(
            "profiles.spaces", passed: spacesPassed,
            "stay: profile=\(stayed.profile == testProfile ? "kept" : stayed.profile) draft=\(stayed.open ? "open" : "closed") "
                + "prompts=\(stayed.prompts) work=\(workID) folder=\(FileManager.default.fileExists(atPath: folder.path)) "
                + "menu=\(menu.filter { $0.hasPrefix("Profile/") }) renderers=\(renderersOne),\(renderersTwo),\(renderersThree)"
        )
        let sharedCount = shared.cookie.split(separator: ";").filter {
            $0.trimmingCharacters(in: .whitespaces) == "who=work"
        }.count
        let personalCookie = other.cookie.contains("who=work") ? other.cookie : "none"
        run.check(
            name, passed: workCookies == 1 && personalCookie == "none" && sharedCount == 1,
            "work_cookie=\(workCookies) personal_cookie=\(personalCookie) shared=\(sharedCount)")
    }
}
