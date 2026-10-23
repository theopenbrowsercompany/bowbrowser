import Foundation

/// Spike S2 (throwaway): several request contexts in one window. Run one at a time with `make e2e E2E=<name>`;
/// `all` never runs them. Fixtures in E2E/Fixtures/s2/.
@MainActor
enum SpikeS2Tests {
    static let all: [any E2ETest] = [
        SpikeS2ContextsTest(), SpikeS2CacheDepthTest(), SpikeS2SharedHandlersTest(), SpikeS2IdleProfilesTest(),
    ]

    static func url(_ query: String) -> URL { E2EFixture.url("s2/index.html?\(query)") }

    static func adapter(_ run: E2ERun) throws -> E2EAppAdapter {
        guard let adapter = run.app as? E2EAppAdapter else { throw E2EError("not the app adapter") }
        return adapter
    }

    /// A direct child of the Chromium root, as the engine places persistent profiles.
    static func directPath(_ run: E2ERun, _ id: String) -> String {
        run.dataDirectory.appendingPathComponent("Profile-\(id)").path
    }

    static func create(_ id: String, cachePath: String?, sharedWith: String? = nil) throws -> Double {
        let seconds = BowSpikeContexts.createProfile(withID: id, cachePath: cachePath, sharedWith: sharedWith)
        guard seconds >= 0 else { throw E2EError("could not create profile \(id)") }
        return seconds
    }

    static func loadAll(_ pages: [any E2EPage]) async throws {
        for page in pages {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }
    }

    static func cookies(_ pages: [any E2EPage]) async throws -> [String] {
        var result: [String] = []
        for page in pages { result.append(try await page.string("document.cookie || 'none'")) }
        return result
    }

    static func setCookie(_ page: any E2EPage, _ value: String) async throws {
        _ = try await page.evaluate("document.cookie = 's2=\(value); Max-Age=3600; SameSite=Lax'")
    }

    static func megabytes(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1_048_576) }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func snapshot() -> [String: Double] {
        BowSpikeContexts.memorySnapshot().mapValues(\.doubleValue)
    }

    /// Settles for `seconds` (a measurement pause, not a wait for a condition).
    static func settle(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Two persistent profiles and one in-memory profile side by side in one window: every page renders, and a cookie
/// set in one profile is absent in the others.
struct SpikeS2ContextsTest: E2ETest {
    let name = "s2.contexts"

    func run(_ run: E2ERun) async throws {
        let ids = ["s2-diskA", "s2-diskB", "s2-memory"]
        let pages = try await run.step("open one window", timeout: E2ETimeouts.step) {
            _ = try SpikeS2Tests.create(ids[0], cachePath: SpikeS2Tests.directPath(run, ids[0]))
            _ = try SpikeS2Tests.create(ids[1], cachePath: SpikeS2Tests.directPath(run, ids[1]))
            _ = try SpikeS2Tests.create(ids[2], cachePath: nil)
            return try await SpikeS2Tests.adapter(run).openSplitWindow(
                at: ids.map { SpikeS2Tests.url("p=\($0)") }, profileIDs: ids)
        }
        try await run.step("load and render", timeout: E2ETimeouts.firstLoad) {
            try await SpikeS2Tests.loadAll(pages)
            for page in pages { try await E2EWaits.untilRendering(page) }
        }
        let windows = Set(pages.compactMap { $0.contentView?.window.map(ObjectIdentifier.init) })
        run.check(
            "s2.one-window", passed: windows.count == 1 && pages.count == 3,
            "pages=\(pages.count) windows=\(windows.count)")

        try await run.step("cookie in one profile", timeout: E2ETimeouts.step) {
            try await SpikeS2Tests.setCookie(pages[0], "A")
            let seen = try await SpikeS2Tests.cookies(pages)
            run.check("s2.cookie-one", passed: seen == ["s2=A", "none", "none"], "seen=\(seen)")
        }
        try await run.step("cookie in each profile", timeout: E2ETimeouts.step) {
            try await SpikeS2Tests.setCookie(pages[1], "B")
            try await SpikeS2Tests.setCookie(pages[2], "M")
            let seen = try await SpikeS2Tests.cookies(pages)
            run.check("s2.cookie-each", passed: seen == ["s2=A", "s2=B", "s2=M"], "seen=\(seen)")
        }
        let paths = ids.map { BowSpikeContexts.cachePath(ofProfile: $0) }
        let exists = ids.map { FileManager.default.fileExists(atPath: SpikeS2Tests.directPath(run, $0)) }
        run.check("s2.folders", passed: exists == [true, true, false], "exists=\(exists) cachePaths=\(paths)")
    }
}

/// The cache_path depth rule: a direct child of the root persists, a deeper path and a path outside the root do not.
struct SpikeS2CacheDepthTest: E2ETest {
    let name = "s2.cache-depth"

    func run(_ run: E2ERun) async throws {
        let root = run.dataDirectory
        let fileManager = FileManager.default
        let spaces = root.appendingPathComponent("Spaces")
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try fileManager.createDirectory(at: spaces, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let cases: [(id: String, path: String)] = [
            ("s2-direct", root.appendingPathComponent("Profile-s2-direct").path),
            ("s2-deep", spaces.appendingPathComponent("Profile-s2-deep").path),
            ("s2-outside", outside.appendingPathComponent("Profile-s2-outside").path),
        ]
        let pages = try await run.step("open one window", timeout: E2ETimeouts.step) {
            for item in cases { _ = try SpikeS2Tests.create(item.id, cachePath: item.path) }
            return try await SpikeS2Tests.adapter(run).openSplitWindow(
                at: cases.map { SpikeS2Tests.url("p=\($0.id)") }, profileIDs: cases.map(\.id))
        }
        try await run.step("load", timeout: E2ETimeouts.firstLoad) { try await SpikeS2Tests.loadAll(pages) }
        try await run.step("write storage", timeout: E2ETimeouts.step) {
            for (index, page) in pages.enumerated() {
                try await SpikeS2Tests.setCookie(page, cases[index].id)
                _ = try await page.evaluate("localStorage.setItem('s2', '\(cases[index].id)')")
            }
        }
        // Give Chromium time to write its stores, then look at what reached disk.
        try await run.step("flush", timeout: 15) { try await SpikeS2Tests.settle(10) }
        var details: [String] = []
        var onDisk: [Bool] = []
        for item in cases {
            let contents = (try? fileManager.contentsOfDirectory(atPath: item.path)) ?? []
            let stored = contents.contains("Local Storage") || contents.contains("Cookies")
            onDisk.append(stored)
            let reported = BowSpikeContexts.cachePath(ofProfile: item.id)
            details.append(
                "\(item.id): folder=\(fileManager.fileExists(atPath: item.path)) stored=\(stored) "
                    + "entries=\(contents.sorted().joined(separator: "|")) getCachePath=\(reported.isEmpty ? "empty" : reported)"
            )
        }
        run.check("s2.cache-depth", passed: onDisk == [true, false, false], details.joined(separator: " ; "))
    }
}

/// CreateContext(other, handler): two Spaces share one profile's storage, each with its own handler.
struct SpikeS2SharedHandlersTest: E2ETest {
    let name = "s2.shared-handlers"

    func run(_ run: E2ERun) async throws {
        let ids = ["s2-base", "s2-spaceX", "s2-spaceY"]
        let pages = try await run.step("open one window", timeout: E2ETimeouts.step) {
            _ = try SpikeS2Tests.create(ids[0], cachePath: SpikeS2Tests.directPath(run, ids[0]))
            _ = try SpikeS2Tests.create(ids[1], cachePath: nil, sharedWith: ids[0])
            _ = try SpikeS2Tests.create(ids[2], cachePath: nil, sharedWith: ids[0])
            return try await SpikeS2Tests.adapter(run).openSplitWindow(
                at: ids.map { SpikeS2Tests.url("space=\($0)") }, profileIDs: ids)
        }
        try await run.step("load", timeout: E2ETimeouts.firstLoad) { try await SpikeS2Tests.loadAll(pages) }
        let sharing = [
            BowSpikeContexts.profile(ids[1], sharesStorageWith: ids[0]),
            BowSpikeContexts.profile(ids[2], sharesStorageWith: ids[0]),
            BowSpikeContexts.profile(ids[1], sharesStorageWith: ids[2]),
        ]
        let paths = ids.map { BowSpikeContexts.cachePath(ofProfile: $0) }
        run.check("s2.is-sharing", passed: !sharing.contains(false), "sharing=\(sharing) cachePaths=\(paths)")

        try await run.step("shared cookie", timeout: E2ETimeouts.step) {
            try await SpikeS2Tests.setCookie(pages[1], "X")
            let seen = try await SpikeS2Tests.cookies(pages)
            run.check("s2.shared-storage", passed: seen == ["s2=X", "s2=X", "s2=X"], "seen=\(seen)")
        }
        // Each handler must have been asked about its own Space's page and never another Space's.
        var details: [String] = []
        var own = true
        for id in ids {
            let urls = BowSpikeContexts.requestURLs(forProfile: id)
            let mine = urls.filter { $0.contains("space=\(id)") }.count
            let others = urls.filter { $0.contains("space=") && !$0.contains("space=\(id)") }.count
            if mine == 0 || others > 0 { own = false }
            details.append(
                "\(id): own=\(mine) others=\(others) init=\(BowSpikeContexts.initializationSeconds(forProfile: id))")
        }
        run.check("s2.per-space-handlers", passed: own, details.joined(separator: " ; "))
    }
}

/// Ten idle persistent profiles: memory per profile with no tab and with one idle tab, and startup cost.
struct SpikeS2IdleProfilesTest: E2ETest {
    let name = "s2.idle-profiles"
    static let count = 10

    func run(_ run: E2ERun) async throws {
        let first = try await run.step("open the default profile", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: SpikeS2Tests.url("p=Default"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        try await run.step("settle", timeout: 10) { try await SpikeS2Tests.settle(5) }
        let before = SpikeS2Tests.snapshot()

        let ids = (0..<Self.count).map { "s2-idle\($0)" }
        var createSeconds: [Double] = []
        try await run.step("create ten profiles", timeout: E2ETimeouts.step) {
            for id in ids {
                createSeconds.append(try SpikeS2Tests.create(id, cachePath: SpikeS2Tests.directPath(run, id)))
            }
            // Initialization is reported on later main thread tasks; wait for every handler.
            while ids.contains(where: { BowSpikeContexts.initializationSeconds(forProfile: $0) < 0 }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let initSeconds = ids.map { BowSpikeContexts.initializationSeconds(forProfile: $0) }
        try await run.step("settle", timeout: 10) { try await SpikeS2Tests.settle(5) }
        let contexts = SpikeS2Tests.snapshot()

        let openStart = Date()
        let pages = try await run.step("one tab per profile in one window", timeout: 30) {
            let pages = try await SpikeS2Tests.adapter(run).openSplitWindow(
                at: ids.map { SpikeS2Tests.url("p=\($0)") }, profileIDs: ids)
            try await SpikeS2Tests.loadAll(pages)
            return pages
        }
        let allLoaded = Date().timeIntervalSince(openStart)
        try await run.step("settle", timeout: 10) { try await SpikeS2Tests.settle(5) }
        let tabs = SpikeS2Tests.snapshot()

        // Startup cost of a page: in a brand new profile against a new tab in a profile already in use.
        let coldStart = Date()
        try await run.step("first page in a new profile", timeout: E2ETimeouts.firstLoad) {
            _ = try SpikeS2Tests.create("s2-cold", cachePath: SpikeS2Tests.directPath(run, "s2-cold"))
            let cold = try await SpikeS2Tests.adapter(run).openSplitWindow(
                at: [SpikeS2Tests.url("p=cold")], profileIDs: ["s2-cold"])
            try await SpikeS2Tests.loadAll(cold)
        }
        let coldSeconds = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        try await run.step("new tab in a profile in use", timeout: E2ETimeouts.firstLoad) {
            let warm = try run.app.openTab(at: SpikeS2Tests.url("p=warm"), besides: pages[0], select: false)
            _ = try await warm.waitForLoad(after: 0)
        }
        let warmSeconds = Date().timeIntervalSince(warmStart)
        _ = first

        let n = Double(Self.count)
        let contextBrowser = (contexts["browser"]! - before["browser"]!) / n
        let contextChildren = (contexts["children"]! - before["children"]!) / n
        let tabBrowser = (tabs["browser"]! - contexts["browser"]!) / n
        let tabChildren = (tabs["children"]! - contexts["children"]!) / n
        let mb = SpikeS2Tests.megabytes
        let detail = [
            "load1=\(String(format: "%.1f", before["load1"]!)),\(String(format: "%.1f", contexts["load1"]!)),\(String(format: "%.1f", tabs["load1"]!))",
            "children=\(Int(before["childCount"]!)),\(Int(contexts["childCount"]!)),\(Int(tabs["childCount"]!))",
            "perProfileNoTab: browserMB=\(mb(contextBrowser)) childrenMB=\(mb(contextChildren))",
            "perProfileOneTab: browserMB=\(mb(tabBrowser)) childrenMB=\(mb(tabChildren))",
            "totalsMB before=\(mb(before["browser"]! + before["children"]!)) contexts=\(mb(contexts["browser"]! + contexts["children"]!)) tabs=\(mb(tabs["browser"]! + tabs["children"]!))",
            "createContextMs median=\(String(format: "%.2f", SpikeS2Tests.median(createSeconds) * 1000)) max=\(String(format: "%.2f", (createSeconds.max() ?? 0) * 1000))",
            "initializedMs median=\(String(format: "%.1f", SpikeS2Tests.median(initSeconds) * 1000)) max=\(String(format: "%.1f", (initSeconds.max() ?? 0) * 1000))",
            "tenTabsLoadedS=\(String(format: "%.2f", allLoaded)) coldProfilePageS=\(String(format: "%.2f", coldSeconds)) warmTabS=\(String(format: "%.2f", warmSeconds))",
        ].joined(separator: " ")
        run.check("s2.idle-profiles", passed: pages.count == Self.count, detail)
    }
}
