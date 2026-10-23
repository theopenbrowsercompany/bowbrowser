import BowCore
import Foundation

/// Tests of the Arc importer inside the app process. Fixtures in E2E/Fixtures/import/ (hand built, never real Arc data).
@MainActor
enum ImportTests {
    static let all: [any E2ETest] = [ImportParseTest()]
}

/// Serves a hand built sidebar file, runs the importer's dry run on its bytes and checks the report's counts.
struct ImportParseTest: E2ETest {
    let name = "import.parse"

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("import/sidebar.json"))
        }
        let data = try await run.step("load fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
            let text = try await page.string("document.body.innerText")
            guard let data = text.data(using: .utf8), !data.isEmpty else { throw E2EError("the fixture is empty") }
            return data
        }
        try await run.step("dry run", timeout: E2ETimeouts.step) {
            let result = try ArcImporter.parse(data)
            let report = result.report
            // The folder depth is also computed from the parsed model, apart from the report's own count.
            let depth =
                result.spaces.map { space in
                    max(Self.depth(of: space.pinned), Self.depth(of: space.unpinned))
                }.max() ?? 0
            let counts = "spaces=\(report.spaces) folders=\(report.folders) depth=\(depth) pinned=\(report.pinnedTabs)"
            let agrees = depth == report.maxFolderDepth && report.skipped.isEmpty
            run.check(
                name, passed: counts == "spaces=3 folders=5 depth=3 pinned=18" && agrees,
                agrees ? counts : "\(counts) (report depth \(report.maxFolderDepth), skipped \(report.skipped.count))")
        }
    }

    private static func depth(of nodes: [ArcImportNode]) -> Int {
        nodes.map { node in
            if case .folder(let folder) = node { return 1 + depth(of: folder.children) }
            return 0
        }.max() ?? 0
    }
}
