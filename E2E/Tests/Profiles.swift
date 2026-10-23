import Foundation

/// Tests of profiles: each has its own storage, and fixture pages load in every profile.
/// Fixtures in E2E/Fixtures/profiles/.
@MainActor
enum ProfilesTests {
    static let all: [any E2ETest] = [ProfilesIsolationTest(), ProfilesSpacesTest()]
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
            try await FavoritesGridTests.settle(read, until: condition)
        }
        /// The page the window shows once it is a page in profile `id` that has loaded.
        func shown(in id: String) async throws -> any E2EPage {
            let page = try await until(
                { try app.shownPage(besides: first) },
                { page in
                    guard let page, !page.isClosed else { return false }
                    return (try? app.tabProfileID(of: page)) == id
                })
            guard let page else { throw E2EError("the window shows no page in profile \(id)") }
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
            _ = try await until({ try app.sheetMessage(in: first) }, { $0 != nil })
            try app.answerSheet("Create Profile", text: workName, in: first)
            _ = try await until({ draft.leavePrompts }, { $0 >= 1 })
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
            _ = try await until({ first.isClosed && draft.isClosed }, { $0 })
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
            _ = try await until({ try app.sheetMessage(in: first) }, { $0 != nil })
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
