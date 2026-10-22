import Foundation

/// Tests of profiles: each has its own storage, and fixture pages load in every profile.
/// Fixtures in E2E/Fixtures/profiles/.
@MainActor
enum ProfilesTests {
    static let all: [any E2ETest] = [ProfilesIsolationTest()]
}

/// Opens windows in the default profile, a new in-memory profile and a new persistent profile, checks that the
/// fixture page loads in each, that site storage written in one is not seen in the others, and that a taken
/// profile ID is refused.
struct ProfilesIsolationTest: E2ETest {
    let name = "profiles.isolation"

    func run(_ run: E2ERun) async throws {
        let url = E2EFixture.url("profiles/index.html")
        let pages = try await run.step("open windows", timeout: E2ETimeouts.step) {
            [
                try run.app.openWindow(at: url),
                try run.app.openWindow(at: url, newProfile: E2EProfile(id: "e2e-memory", isPersistent: false)),
                try run.app.openWindow(at: url, newProfile: E2EProfile(id: "e2e-disk", isPersistent: true)),
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
            var refused: [String] = []
            for id in ["Default", "e2e-memory", "E2E-DISK"] {
                do {
                    _ = try run.app.openWindow(at: url, newProfile: E2EProfile(id: id, isPersistent: false))
                } catch {
                    refused.append(id)
                }
            }
            run.check("profiles.taken", passed: refused.count == 3, "refused=\(refused.joined(separator: ","))")
        }
    }
}
