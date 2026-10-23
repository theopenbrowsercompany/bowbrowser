import Foundation

/// Tests of tabs in one window: switching shows another live page without reloading either one.
/// Fixtures in E2E/Fixtures/tabs/.
@MainActor
enum TabsTests {
    static let all: [any E2ETest] = [TabsSwitchTest(), TabsCloseWindowTest()]
}

/// Closes a window holding three tabs, one shown and two parked, and checks that every tab closes and the window
/// follows, while the app keeps running.
struct TabsCloseWindowTest: E2ETest {
    let name = "tabs.close-window"

    func run(_ run: E2ERun) async throws {
        let url = E2EFixture.url("tabs/counter.html?name=c")
        let pages = try await run.step("open three tabs", timeout: E2ETimeouts.step) {
            let first = try await run.app.openWindow(at: url)
            return [
                first,
                try run.app.openTab(at: url, besides: first, select: false),
                try run.app.openTab(at: url, besides: first, select: false),
            ]
        }
        try await run.step("load tabs", timeout: E2ETimeouts.firstLoad) {
            for page in pages {
                let status = try await page.waitForLoad(after: 0)
                guard status == 200 else { throw E2EError("a tab loaded with status \(status)") }
            }
        }
        try await run.step("close window", timeout: E2ETimeouts.step) {
            try await run.app.closeWindow(of: pages[0])
        }
        let closed = pages.filter(\.isClosed).count
        run.check(name, passed: closed == pages.count, "closed=\(closed)/\(pages.count)")
    }
}

/// Opens two tabs in one window, switches between them a few times, and checks that neither page reloaded,
/// counting loads three ways: the page's own load counter in sessionStorage, the page's per-document ID, and the
/// engine's load events. Also checks that the tab not shown counts as hidden while the shown one paints.
struct TabsSwitchTest: E2ETest {
    let name = "tabs.switch"
    static let rounds = 3

    func run(_ run: E2ERun) async throws {
        let first = try await run.step("open window", timeout: E2ETimeouts.step) {
            try await run.app.openWindow(at: E2EFixture.url("tabs/counter.html?name=a"))
        }
        try await run.step("load first tab", timeout: E2ETimeouts.firstLoad) {
            try await Self.expectLoaded(first, name: "a")
        }
        let second = try await run.step("open second tab", timeout: E2ETimeouts.step) {
            try run.app.openTab(at: E2EFixture.url("tabs/counter.html?name=b"), besides: first, select: true)
        }
        try await run.step("load second tab", timeout: E2ETimeouts.firstLoad) {
            try await Self.expectLoaded(second, name: "b")
            guard second.isShown, !first.isShown else { throw E2EError("the new tab is not the one shown") }
        }
        let loadIDs = try await run.step("record pages", timeout: E2ETimeouts.step) {
            let visible = try await Self.visibility(of: second, becoming: "visible")
            guard visible == "visible" else { throw E2EError("the new tab is \(visible)") }
            return [try await first.string("window.bowLoadID"), try await second.string("window.bowLoadID")]
        }

        var hiddenStates: [String] = []
        var slowestShow: TimeInterval = 0
        for round in 1...Self.rounds {
            for (shown, other) in [(first, second), (second, first)] {
                let label = shown === first ? "a" : "b"
                try await run.step("show \(label), round \(round)", timeout: E2ETimeouts.step) {
                    let start = Date()
                    try run.app.select(shown)
                    let visible = try await Self.visibility(of: shown, becoming: "visible")
                    guard visible == "visible" else { throw E2EError("the shown tab is \(visible)") }
                    slowestShow = max(slowestShow, Date().timeIntervalSince(start))
                    try await E2EWaits.untilRendering(shown)
                    hiddenStates.append(try await Self.visibility(of: other, becoming: "hidden"))
                }
            }
        }

        try await run.step("count reloads", timeout: E2ETimeouts.step) {
            var reloads = 0
            var details: [String] = []
            for (page, loadID, label) in [(first, loadIDs[0], "a"), (second, loadIDs[1], "b")] {
                let pageLoads = Int(try await page.string("sessionStorage.getItem('loads') ?? '0'")) ?? 0
                let sameDocument = try await page.string("window.bowLoadID") == loadID
                let engineLoads = page.finishedLoads
                let tabReloads = max(pageLoads - 1, engineLoads - 1, sameDocument ? 0 : 1)
                reloads += tabReloads
                if tabReloads > 0 {
                    details.append(
                        "\(label): page loads \(pageLoads), engine loads \(engineLoads), same document \(sameDocument)")
                }
            }
            let detail = details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
            run.check(name, passed: reloads == 0, "reloads=\(reloads)\(detail)")
        }
        let notHidden = hiddenStates.filter { $0 != "hidden" }
        run.check(
            "tabs.hidden",
            passed: notHidden.isEmpty,
            notHidden.isEmpty
                ? "switches=\(hiddenStates.count) detached=hidden slowest-show=\(String(format: "%.2f", slowestShow))s"
                : "the tab not shown was \(notHidden.joined(separator: ", ")) in \(notHidden.count) of \(hiddenStates.count) switches"
        )
    }

    private static func expectLoaded(_ page: any E2EPage, name: String) async throws {
        let status = try await page.waitForLoad(after: 0)
        guard status == 200 else { throw E2EError("tab \(name) loaded with status \(status)") }
        let title = try await page.string("document.title")
        guard title == "Tab \(name)" else { throw E2EError("tab \(name) has the title \"\(title)\"") }
    }

    /// The page's visibility once it becomes `state`, or after two seconds if it does not, so a wrong state is
    /// reported as a failed check rather than a timeout.
    private static func visibility(of page: any E2EPage, becoming state: String) async throws -> String {
        try await page.string(
            """
            new Promise(resolve => {
              if (document.visibilityState === "\(state)") return resolve(document.visibilityState);
              const timer = setTimeout(() => resolve(document.visibilityState), 2000);
              document.addEventListener("visibilitychange", () => {
                if (document.visibilityState !== "\(state)") return;
                clearTimeout(timer);
                resolve(document.visibilityState);
              });
            })
            """
        )
    }
}
