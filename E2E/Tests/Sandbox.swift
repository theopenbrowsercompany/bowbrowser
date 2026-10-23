import Foundation

/// Tests that Chromium's helpers run inside the macOS sandbox. Uses the fixtures in E2E/Fixtures/app/.
@MainActor
enum SandboxTests {
    static let all: [any E2ETest] = [SandboxTest()]
}

/// With a fixture page rendering, reads the app's helper processes from the kernel and checks that every
/// renderer, the GPU process and the network service were started with `--seatbelt-client` and are sandboxed,
/// and that no helper turns the sandbox off.
struct SandboxTest: E2ETest {
    let name = "sandbox"
    let checks = ["sandbox.renderers", "sandbox.gpu", "sandbox.network", "sandbox.switches"]

    /// The helper kinds that must be sandboxed, by check name.
    private static let required: [(check: String, matches: (Helper) -> Bool)] = [
        ("sandbox.renderers", { $0.type == "renderer" }),
        ("sandbox.gpu", { $0.type == "gpu-process" }),
        ("sandbox.network", { $0.type == "utility" && $0.utilitySubType == "network.mojom.NetworkService" }),
    ]
    private static let forbiddenSwitches = ["--no-sandbox", "--single-process", "--disable-gpu-sandbox"]
    /// A helper that has just started may not have entered the sandbox yet, so the processes are read again
    /// until every required helper is sandboxed or this much time has passed.
    private static let settleTimeout: TimeInterval = 3

    func run(_ run: E2ERun) async throws {
        let page = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("app/index.html"))
        }
        try await run.step("load fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
            try await E2EWaits.untilRendering(page)
        }
        let helpers = try await run.step("read helpers", timeout: E2ETimeouts.step) {
            try await Self.settledHelpers()
        }

        for (check, matches) in Self.required {
            let group = helpers.filter(matches)
            if let failure = Self.failure(of: group) {
                run.check(check, passed: false, failure)
            } else {
                run.check(check, passed: true, "sandboxed=\(group.count)")
            }
        }

        let offending = helpers.lazy.compactMap { helper in
            helper.firstSwitch(in: Self.forbiddenSwitches).map { "pid \(helper.pid) (\(helper.label)) runs with \($0)" }
        }.first
        if let offending {
            run.check("sandbox.switches", passed: false, offending)
        } else {
            run.check("sandbox.switches", passed: true, "helpers=\(helpers.count)")
        }
    }

    /// Why one required kind of helper fails, or nil when at least one runs and every one is sandboxed.
    private static func failure(of group: [Helper]) -> String? {
        if let helper = group.first(where: { !$0.hasSeatbeltClient }) {
            return "pid \(helper.pid) (\(helper.label)) was started without --seatbelt-client"
        }
        if let helper = group.first(where: { !$0.sandboxed }) {
            return "pid \(helper.pid) (\(helper.label)) is not sandboxed"
        }
        return group.isEmpty ? "no such process is running" : nil
    }

    /// The helpers once every required one is sandboxed, or as they are when the settle time runs out.
    private static func settledHelpers() async throws -> [Helper] {
        let deadline = Date().addingTimeInterval(settleTimeout)
        while true {
            let helpers = BowChildProcess.childrenOfCurrentProcess().compactMap(Helper.init)
            let settled = required.allSatisfy { _, matches in failure(of: helpers.filter(matches)) == nil }
            if settled || Date() >= deadline { return helpers }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// A Chromium helper process: a child process with a `--type` switch.
private struct Helper {
    let pid: pid_t
    let arguments: [String]
    let sandboxed: Bool
    let type: String
    let utilitySubType: String?

    init?(_ process: BowChildProcess) {
        pid = process.pid
        arguments = process.arguments
        sandboxed = process.isSandboxed
        guard let type = Self.value(of: "--type", in: arguments) else { return nil }
        self.type = type
        utilitySubType = Self.value(of: "--utility-sub-type", in: arguments)
    }

    var hasSeatbeltClient: Bool { Self.value(of: "--seatbelt-client", in: arguments) != nil }

    /// The type, with the utility sub-type when there is one, for FAIL lines.
    var label: String { utilitySubType.map { "\(type) \($0)" } ?? type }

    /// The first of `switches` this helper was started with, alone or with a value.
    func firstSwitch(in switches: [String]) -> String? {
        switches.first { name in arguments.contains { $0 == name || $0.hasPrefix(name + "=") } }
    }

    private static func value(of name: String, in arguments: [String]) -> String? {
        arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
    }
}
