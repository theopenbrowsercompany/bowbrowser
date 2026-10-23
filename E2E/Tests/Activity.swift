import Foundation

/// Tests of the tab activity log: selecting a tab records it as the most recently active. Uses the store fixture.
@MainActor
enum ActivityTests {
    static let all: [any E2ETest] = [
        ActivityLastTest()
    ]
}

/// Opens tabs A and B, selects A and then B, and checks B's last active time is later than A's.
struct ActivityLastTest: E2ETest {
    let name = "activity"
    let checks = ["activity"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EActivityApp else { throw E2EError("the app has no activity log to read") }
        let (a, b) = try await run.step("open A and B", timeout: E2ETimeouts.firstLoad) {
            let a = try await run.app.openWindow(at: StoreTests.url("A"))
            _ = try await a.waitForLoad(after: 0)
            let b = try run.app.openTab(at: StoreTests.url("B"), besides: a, select: true)
            _ = try await b.waitForLoad(after: 0)
            return (a, b)
        }
        let times = try await run.step("select A then B", timeout: E2ETimeouts.step) {
            try run.app.select(a)
            // Times are compared, so keep the two selections apart.
            try await Task.sleep(nanoseconds: 50_000_000)
            try run.app.select(b)
            return (try app.activityTime(of: a), try app.activityTime(of: b))
        }
        guard let timeA = times.0, let timeB = times.1 else {
            run.check(
                name, passed: false,
                "a tab has no recorded time: A=\(String(describing: times.0)) B=\(String(describing: times.1))")
            return
        }
        let last = timeB > timeA ? "B" : "A"
        run.check(name, passed: last == "B", "last=\(last)")
    }
}
