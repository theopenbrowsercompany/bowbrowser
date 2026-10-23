import Foundation

/// The opt-in hidden tab measurement: what hidden tabs cost in CPU, wakeups, energy and memory with one tab attached
/// per window and the rest parked. Each run is selected only by its exact name (`selectedByNameOnly`), so `all`,
/// areas (`s3`), globs and tags never start one; it sets its own engine switches and time limit, and writes its
/// figures to `<run folder>/s3.json`. Its checks assert only that the figures were collected and the preconditions
/// held (the engine's switches, a renderer per site, which tabs counted as visible), never a threshold.
///
///   make e2e E2E=s3.smoke E2E_RETRY=0                  3 tabs, every pass for a few seconds: proves collection
///   make e2e E2E=s3.hidden-tabs-control E2E_RETRY=0    30 tabs, harness switches, passes V, D, DF (about 9 min)
///   make e2e E2E=s3.hidden-tabs E2E_RETRY=0            30 tabs, Chromium's own throttling, every pass (about 30 min)
///
/// The full runs belong on a quiet machine with no other builds; a pass whose 1 minute load average was above 2 is
/// repeated once and flagged. Fixtures in E2E/Fixtures/s3/, served from t00.test to t29.test.
@MainActor
enum S3Tests {
    static let all: [any E2ETest] = [
        S3OptInTest(), S3RunTest(run: .smoke), S3RunTest(run: .control), S3RunTest(run: .realistic),
    ]
}

/// Checks that no normal selection ever starts a measurement run, that each run is selected by its name alone, and
/// that runs needing different engine switches are refused together.
struct S3OptInTest: E2ETest {
    let name = "s3.opt-in"
    let checks = ["s3.opt-in", "s3.switch-override"]

    func run(_ run: E2ERun) async throws {
        let runs = Set(S3RunTest.Run.allCases.map(\.rawValue))
        try await run.step("select", timeout: E2ETimeouts.step) {
            var picked: [String] = []
            for selection in ["all", "s3", "s3.*", "s3.hidden-tabs*", "smoke", "s3.opt-in"] {
                let chosen = try E2ETests.select(selection).map(\.name)
                picked += chosen.filter(runs.contains).map { "\(selection) picked \($0)" }
            }
            for name in runs.sorted() {
                let chosen = try E2ETests.select(name).map(\.name)
                if chosen != [name] { picked.append("\(name) selected \(chosen)") }
            }
            run.check(
                "s3.opt-in", passed: picked.isEmpty,
                picked.isEmpty
                    ? "all, s3, s3.*, s3.hidden-tabs*, smoke and s3.opt-in pick no run; each run selects only itself"
                    : picked.joined(separator: "; "))

            let base = E2ERunner.harnessSwitches(loopbackRules: "")
            let realistic = S3RunTest(run: .realistic)
            let switches = try E2ETests.switches(for: [realistic], base: base)
            let mixed = (try? E2ETests.switches(for: [realistic, S3RunTest(run: .control)], base: base)) != nil
            let dropped = switches["disable-renderer-backgrounding"] == nil
                && switches["disable-background-timer-throttling"] == nil
            let kept = switches["disable-backgrounding-occluded-windows"] != nil
                && switches["autoplay-policy"] == "no-user-gesture-required"
            run.check(
                "s3.switch-override", passed: dropped && kept && !mixed,
                "realistic drops throttling switches=\(dropped) keeps occlusion and adds autoplay=\(kept) "
                    + "mixed with control refused=\(!mixed)")
        }
    }
}

/// One measurement run: opens its tabs, runs its passes and writes s3.json.
struct S3RunTest: E2ETest {
    /// The runs, by test name. Names are the raw values rather than stored string literals, the form `make done`
    /// reads to repeat changed tests, so it never repeats a 30 minute run.
    enum Run: String, CaseIterable {
        case smoke = "s3.smoke"
        case control = "s3.hidden-tabs-control"
        case realistic = "s3.hidden-tabs"
    }

    let run: Run
    var name: String { run.rawValue }
    var selectedByNameOnly: Bool { true }
    var checks: [String] { ["switches", "sites", "visibility", "collected", "written"].map { "\(name).\($0)" } }
    var switchOverride: E2ESwitchOverride? { config.switches }
    /// Every pass twice (a repeat for load) plus time to open and close 30 windows.
    var timeLimit: TimeInterval { config.passes.map { config.seconds(of: $0) + 30 }.reduce(0, +) * 2 + 300 }

    var config: S3Config {
        switch run {
        case .smoke: return .smoke
        case .control: return .control
        case .realistic: return .realistic
        }
    }

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2ES3App, let unload = run.app as? any E2EUnloadApp else {
            throw E2EError("the app does not drive the S3 measurement")
        }
        let session = S3Session(test: self, run: run, app: app)
        do {
            try await run.step("turn the unloader off", timeout: E2ETimeouts.step) {
                // Parked tabs must stay loaded for the whole run.
                try unload.setUnloadEnabled(false)
            }
            try await session.measure()
        } catch {
            await session.stop()
            await session.write(error: error)
            throw error
        }
        try await run.step("write s3.json", timeout: E2ETimeouts.step) {
            let written = await session.write(error: nil)
            run.check("\(name).written", passed: written.ok, written.detail)
        }
    }
}

/// The passes, each a row of the design: hidden tabs attached and visible (V), detached (D), detached with
/// WasHidden (DH), frozen (DF), detached for a long pass (DL), audible (DA), audible and muted (DAM), a lower
/// windowless frame rate (FR, a no op for windowed browsers) and closed (U).
enum S3Pass: String, CaseIterable {
    case V, D, DH, DF, DL, DA, DAM, FR, U
}

struct S3Config {
    var tabs: Int
    var audioTabs: Int
    var passes: [S3Pass]
    var settle: TimeInterval
    var measure: TimeInterval
    /// The long pass's measuring, in parts with the page counters read between them (5 minutes, then 1.5).
    var longSegments: [TimeInterval]
    var topSamples: Int
    var topInterval: Int
    var repeatsOnLoad: Bool
    var switches: E2ESwitchOverride?

    func segments(of pass: S3Pass) -> [TimeInterval] { pass == .DL ? longSegments : [measure] }
    func seconds(of pass: S3Pass) -> TimeInterval { settle + segments(of: pass).reduce(0, +) }

    /// Chromium's own background throttling back on, occlusion still off so the attached tab in an off screen
    /// window stays visible, and audio allowed to start without a gesture.
    static let realisticSwitches = E2ESwitchOverride(
        removing: ["disable-renderer-backgrounding", "disable-background-timer-throttling"],
        adding: ["autoplay-policy": "no-user-gesture-required"])

    static let realistic = S3Config(
        tabs: 30, audioTabs: 5, passes: S3Pass.allCases, settle: 30, measure: 120, longSegments: [300, 90],
        topSamples: 3, topInterval: 10, repeatsOnLoad: true, switches: realisticSwitches)
    static let control = S3Config(
        tabs: 30, audioTabs: 0, passes: [.V, .D, .DF], settle: 30, measure: 120, longSegments: [],
        topSamples: 3, topInterval: 10, repeatsOnLoad: true, switches: nil)
    static let smoke = S3Config(
        tabs: 3, audioTabs: 1, passes: S3Pass.allCases, settle: 2, measure: 6, longSegments: [4, 2],
        topSamples: 2, topInterval: 2, repeatsOnLoad: false, switches: realisticSwitches)
}

/// One tab of the run: its site, its load and its page.
@MainActor
final class S3Tab {
    let index: Int
    var load: String
    let page: any E2EPage
    var site: String { String(format: "t%02d.test", index) }

    init(index: Int, load: String, page: any E2EPage) {
        self.index = index
        self.load = load
        self.page = page
    }

    static func url(_ index: Int, load: String) -> URL {
        URL(string: String(format: "https://t%02d.test/s3/tab.html?load=%@", index, load))!
    }
}

/// The run's state and its results as it goes.
@MainActor
final class S3Session {
    private let test: S3RunTest
    private let run: E2ERun
    private let app: any E2ES3App
    private var config: S3Config { test.config }
    /// The tab attached in the measuring window, then the parked ones.
    private var tabs: [S3Tab] = []
    /// One page per window in pass V, besides `tabs[0]`'s.
    private var windowPages: [any E2EPage] = []
    private var passes: [[String: Any]] = []
    private var top: E2ES3Top?
    private let started = Date()
    private var switches: [String: Any] = [:]

    init(test: S3RunTest, run: E2ERun, app: any E2ES3App) {
        self.test = test
        self.run = run
        self.app = app
    }

    private func checkName(_ part: String) -> String { "\(test.name).\(part)" }

    func measure() async throws {
        try await run.step("check the engine switches", timeout: E2ETimeouts.step) { self.checkSwitches() }
        let passes = config.passes
        if passes.contains(.V) {
            try await run.step("open \(config.tabs) windows", timeout: 60 + Double(config.tabs) * 3) {
                try await self.openWindows()
            }
            try await pass(.V)
            try await run.step("close all windows but the first", timeout: 30 + Double(config.tabs)) {
                for page in self.windowPages { try await self.app.closeWindow(of: page) }
                self.windowPages = []
                self.tabs = Array(self.tabs.prefix(1))
            }
        } else {
            try await run.step("open the window", timeout: E2ETimeouts.firstLoad) {
                let page = try await self.app.openWindow(at: S3Tab.url(0, load: "busy"))
                try await self.loaded(page)
                self.tabs = [S3Tab(index: 0, load: "busy", page: page)]
            }
        }
        try await run.step("open \(config.tabs - 1) tabs unselected", timeout: 60 + Double(config.tabs) * 2) {
            try await self.openParkedTabs()
        }
        for pass in passes where pass != .V { try await self.pass(pass) }
        recordChecks()
    }

    // MARK: Opening

    private func openWindows() async throws {
        for index in 0..<config.tabs {
            let page = try await app.openWindow(at: S3Tab.url(index, load: "busy"))
            try await loaded(page)
            tabs.append(S3Tab(index: index, load: "busy", page: page))
            if index > 0 { windowPages.append(page) }
        }
    }

    private func openParkedTabs() async throws {
        let first = tabs[0].page
        for index in 1..<config.tabs {
            let page = try app.openTab(at: S3Tab.url(index, load: "busy"), besides: first, select: false)
            tabs.append(S3Tab(index: index, load: "busy", page: page))
        }
        for tab in tabs.dropFirst() { try await loaded(tab.page) }
        guard first.isShown else { throw E2EError("the first tab is not the one shown after opening the others") }
    }

    private func loaded(_ page: any E2EPage, after finished: Int = 0) async throws {
        let status = try await page.waitForLoad(after: finished)
        guard status == 200 else { throw E2EError("a tab loaded with status \(status)") }
        try await E2EWaits.until(page, "window.bowS3 !== undefined")
    }

    // MARK: Passes

    private var parked: [S3Tab] { Array(tabs.dropFirst()) }
    private var audible: [S3Tab] { Array(parked.prefix(config.audioTabs)) }

    /// Runs one pass, and once more when the machine was busy (load average above 2) and the run repeats.
    private func pass(_ pass: S3Pass) async throws {
        let limit = config.seconds(of: pass) + 60 + Double(tabs.count)
        var attempt = 1
        while true {
            let result = try await run.step("pass \(pass.rawValue) attempt \(attempt)", timeout: limit) {
                try await self.runPass(pass, attempt: attempt)
            }
            passes.append(result)
            let busy = result["flagged"] as? Bool ?? false
            guard busy, config.repeatsOnLoad, attempt == 1 else { return }
            attempt += 1
        }
    }

    private func runPass(_ pass: S3Pass, attempt: Int) async throws -> [String: Any] {
        var extra: [String: Any] = [:]
        let loadBefore = e2eS3LoadAverage()
        // Puts the tabs in the pass's state. Counters are reset first, since a frozen page answers nothing.
        try await takeAll()
        switch pass {
        case .V, .D: break
        case .DH:
            extra["wasHiddenCalled"] = try parked.map { try app.s3SetWasHidden(true, $0.page) }.allSatisfy { $0 }
        case .DF:
            for tab in parked { _ = try await tab.page.devTools("Page.setWebLifecycleState", ["state": "frozen"]) }
            extra["frozen"] = parked.count
        case .DL:
            // Fresh hidden pages, so the long pass sees intensive throttling begin 5 minutes after hiding.
            try await reload(parked, load: "busy")
            try await takeAll()
            extra["reloadedAtStart"] = true
        case .DA:
            try await reload(audible, load: "audio")
            try await takeAll()
            extra["audioTabs"] = audible.map(\.site)
        case .DAM:
            extra["mutedCalled"] = try audible.map { try app.s3SetAudioMuted(true, $0.page) }.allSatisfy { $0 }
            extra["mutedReported"] = try audible.map { try app.s3IsAudioMuted($0.page) }.allSatisfy { $0 }
        case .FR:
            extra["frameRateCalled"] = try tabs.map { try app.s3SetWindowlessFrameRate(1, $0.page) }
                .allSatisfy { $0 }
        case .U:
            for tab in parked { _ = try await app.closeTab(tab.page) }
            tabs = Array(tabs.prefix(1))
            extra["closed"] = config.tabs - 1
        }
        let frozen = pass == .DF

        try await pause(config.settle)
        if !frozen { try await takeAll() }
        let renderers = E2ES3Processes.rendererCount()
        let measureStart = Date()
        let startUsage = E2ES3Processes.snapshot()
        let top = E2ES3Top(
            pids: Array(startUsage.keys).sorted(), samples: config.topSamples, interval: config.topInterval)
        self.top = top
        var samples = [[E2ES3TaskSample]](repeating: [], count: tabs.count)
        var segmentPages: [[String: Any]] = []
        let segments = config.segments(of: pass)
        for (number, seconds) in segments.enumerated() {
            try await sampleTasks(for: seconds, into: &samples)
            if segments.count > 1 && number < segments.count - 1 {
                segmentPages.append(["afterSeconds": seconds, "tabs": try await takeAll()])
            }
        }
        let endUsage = E2ES3Processes.snapshot()
        let measured = Date().timeIntervalSince(measureStart)
        let topResult = await top.rows()
        self.top = nil
        if frozen {
            for tab in parked { _ = try await tab.page.devTools("Page.setWebLifecycleState", ["state": "active"]) }
        }
        let pages = try await takeAll()
        // Undoes the per tab states that would carry into the next pass.
        switch pass {
        case .DH: for tab in parked { _ = try app.s3SetWasHidden(false, tab.page) }
        case .DAM: for tab in audible { _ = try app.s3SetAudioMuted(false, tab.page) }
        case .FR: for tab in tabs { _ = try app.s3SetWindowlessFrameRate(30, tab.page) }
        default: break
        }
        if pass == .DAM { try await reload(audible, load: "busy") }
        let loadAfter = e2eS3LoadAverage()
        let flagged = (loadBefore.first ?? 0) > 2 || (loadAfter.first ?? 0) > 2

        let processes = E2ES3Processes.rates(from: startUsage, to: endUsage, seconds: measured)
        var tabRows: [[String: Any]] = []
        for (index, tab) in tabs.enumerated() {
            let cpu = e2eS3Stats(samples[index].map(\.cpu))
            let memory = samples[index].last.map { Double($0.memory) / 1_048_576 } ?? -1
            tabRows.append([
                "site": tab.site, "load": tab.load, "attached": index == 0,
                "taskManager": [
                    "samples": samples[index].count, "cpuMean": cpu.mean, "cpuP95": cpu.p95,
                    "memoryMB": (memory * 100).rounded() / 100,
                ],
                "page": pages.count > index ? pages[index] : [:],
            ])
        }
        var result: [String: Any] = [
            "pass": pass.rawValue, "attempt": attempt, "flagged": flagged,
            "loadBefore": loadBefore, "loadAfter": loadAfter,
            "settleSeconds": config.settle, "measuredSeconds": (measured * 100).rounded() / 100,
            "openTabs": tabs.count, "renderers": renderers,
            "tabs": tabRows, "processes": processes, "processTotals": E2ES3Processes.totals(processes),
            "top": topResult, "extra": extra,
        ]
        if !segmentPages.isEmpty { result["segments"] = segmentPages }
        return result
    }

    /// Reads and resets every open tab's counters, in tab order.
    @discardableResult
    private func takeAll() async throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        for tab in tabs {
            let json = try await tab.page.string("window.bowS3.take()")
            let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
            all.append(value)
        }
        return all
    }

    private func reload(_ list: [S3Tab], load: String) async throws {
        for tab in list {
            let finished = tab.page.finishedLoads
            try tab.page.load(S3Tab.url(tab.index, load: load))
            try await loaded(tab.page, after: finished)
            tab.load = load
        }
    }

    /// Reads the task manager for every open tab once a second for `seconds`.
    private func sampleTasks(for seconds: TimeInterval, into samples: inout [[E2ES3TaskSample]]) async throws {
        let end = Date().addingTimeInterval(seconds)
        var next = Date()
        while next < end {
            for (index, tab) in tabs.enumerated() {
                if let sample = try app.s3TaskSample(tab.page) { samples[index].append(sample) }
            }
            next = next.addingTimeInterval(1)
            try await pause(min(next, end).timeIntervalSinceNow)
        }
    }

    /// The measurement's fixed settle and sampling times; nothing here waits on a page or app state.
    private func pause(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    // MARK: Checks and results

    private func checkSwitches() {
        let names = [
            "disable-renderer-backgrounding", "disable-background-timer-throttling",
            "disable-backgrounding-occluded-windows", "disable-features", "autoplay-policy",
        ]
        for name in names { switches[name] = BowS3Probe.switchValue(name) ?? NSNull() }
        let expected = test.switchOverride?.applied(to: E2ERunner.harnessSwitches(loopbackRules: ""))
            ?? E2ERunner.harnessSwitches(loopbackRules: "")
        let wrong = names.filter { (BowS3Probe.switchValue($0)) != expected[$0] }
        run.check(
            checkName("switches"), passed: wrong.isEmpty,
            wrong.isEmpty
                ? names.map { "\($0)=\(expected[$0] == nil ? "off" : "on")" }.joined(separator: " ")
                : "the engine's switches differ from the run's for \(wrong.joined(separator: ", "))")
    }

    private func recordChecks() {
        let first = passes.filter { ($0["attempt"] as? Int) == 1 }
        // A renderer per site: as many renderers as open tabs (a spare renderer may add one).
        let short = first.filter { ($0["renderers"] as? Int ?? 0) < ($0["openTabs"] as? Int ?? 0) }
        run.check(
            checkName("sites"), passed: short.isEmpty,
            short.isEmpty
                ? first.map { "\($0["pass"]!)=\($0["renderers"]!)/\($0["openTabs"]!)" }.joined(separator: " ")
                : "fewer renderers than tabs in " + short.map { "\($0["pass"]!)" }.joined(separator: ", "))

        var wrong: [String] = []
        for pass in first {
            guard let name = pass["pass"] as? String, let rows = pass["tabs"] as? [[String: Any]] else { continue }
            for row in rows {
                let attached = row["attached"] as? Bool ?? false
                let visibility = (row["page"] as? [String: Any])?["visibility"] as? String ?? "unread"
                let expected = attached || name == "V" ? "visible" : "hidden"
                if visibility != expected { wrong.append("\(name) \(row["site"]!) \(visibility)") }
            }
        }
        run.check(
            checkName("visibility"), passed: wrong.isEmpty,
            wrong.isEmpty
                ? "V all visible; attached visible and parked hidden in every other pass"
                : wrong.prefix(5).joined(separator: "; "))

        var missing: [String] = []
        for pass in first {
            let name = pass["pass"] as? String ?? "?"
            let rows = pass["tabs"] as? [[String: Any]] ?? []
            let open = pass["openTabs"] as? Int ?? 0
            let sampled = rows.filter { ($0["taskManager"] as? [String: Any])?["samples"] as? Int ?? 0 > 0 }.count
            let paged = rows.filter { ($0["page"] as? [String: Any])?["ticks"] != nil }.count
            let processes = (pass["processes"] as? [[String: Any]])?.count ?? 0
            let topRows = ((pass["top"] as? [String: Any])?["rows"] as? [[String: Any]])?.count ?? 0
            if sampled < open { missing.append("\(name) task manager \(sampled)/\(open)") }
            if paged < open { missing.append("\(name) page counters \(paged)/\(open)") }
            if processes < open + 1 { missing.append("\(name) processes \(processes)") }
            if topRows == 0 { missing.append("\(name) top \((pass["top"] as? [String: Any])?["error"] ?? "no rows")") }
        }
        let ran = Set(first.compactMap { $0["pass"] as? String })
        let notRun = config.passes.map(\.rawValue).filter { !ran.contains($0) }
        if !notRun.isEmpty { missing.append("not run: \(notRun.joined(separator: ", "))") }
        run.check(
            checkName("collected"), passed: missing.isEmpty,
            missing.isEmpty
                ? "passes=\(first.count) task manager, rusage, top and page counters for every open tab"
                : missing.prefix(6).joined(separator: "; "))
    }

    /// Stops what a failed pass left running.
    func stop() async {
        top?.stop()
        top = nil
    }

    /// Writes (or adds this run to) `<run folder>/s3.json`, also after a failure, so a broken run still leaves what
    /// it collected.
    @discardableResult
    func write(error: Error?) async -> (ok: Bool, detail: String) {
        let url = run.outputDirectory.appendingPathComponent("s3.json")
        var document: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            document = existing
        }
        var runs = document["runs"] as? [String: Any] ?? [:]
        var entry: [String: Any] = [
            "startedAt": ISO8601DateFormatter().string(from: started),
            "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
            "processors": ProcessInfo.processInfo.activeProcessorCount,
            "switches": switches,
            "config": [
                "tabs": config.tabs, "audioTabs": config.audioTabs, "passes": config.passes.map(\.rawValue),
                "settleSeconds": config.settle, "measureSeconds": config.measure,
                "longSegments": config.longSegments, "topSamples": config.topSamples,
                "topInterval": config.topInterval,
            ],
            "notAvailable": [
                "powermetrics": "needs root, so package and GPU power are not read",
                "FR": "CEF 156 has frame rate control for windowless browsers only; the pass records that the call "
                    + "changes nothing",
            ],
            "passes": passes,
        ]
        if let error { entry["error"] = "\(error)" }
        runs[test.name] = entry
        document["runs"] = runs
        do {
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            _ = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return (true, "\(url.lastPathComponent) passes=\(passes.count) bytes=\(data.count)")
        } catch {
            return (false, "cannot write \(url.path): \(error.localizedDescription)")
        }
    }
}
