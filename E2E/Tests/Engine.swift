import BowCore
import Foundation

/// Tests that each engine hook reaches the app: the popup decision, keys before the page, per site zoom and unload.
/// They drive engine tabs with no window (`E2EEngineProbe`), since the window answers these hooks with their
/// defaults until the features that use them land. Fixtures in E2E/Fixtures/engine/.
@MainActor
enum EngineTests {
    static let all: [any E2ETest] = [EngineHooksTest()]
}

/// Opens a probe tab on the fixture and walks it through every hook, one check each.
struct EngineHooksTest: E2ETest {
    let name = "engine.hooks"
    let checks = ["engine.popup", "engine.key", "engine.zoom", "engine.unload"]

    func run(_ run: E2ERun) async throws {
        var probes: [E2EEngineProbe] = []
        do {
            try await hooks(run) { probes.append($0) }
        } catch {
            for probe in probes { await probe.close() }
            throw error
        }
        try await run.step("close the probes", timeout: E2ETimeouts.step) {
            for probe in probes { await probe.close() }
        }
    }

    private func hooks(_ run: E2ERun, track: @escaping (E2EEngineProbe) -> Void) async throws {
        let profile = try E2EEngineProbe.makeProfile()
        let probe = try E2EEngineProbe.open(E2EFixture.url("engine/index.html"), in: profile)
        track(probe)
        try await run.step("load the fixture", timeout: E2ETimeouts.firstLoad) {
            let status = try await probe.waitForLoad(1)
            guard status == 200 else { throw E2EError("the fixture loaded with status \(status)") }
        }

        // A page's window.open from a click is decided by the app, which asks for a background tab: the page
        // arrives as a tab of its own, still connected to its opener.
        let opener = try await run.step("open a popup as a tab", timeout: E2ETimeouts.step * 2) {
            probe.popupDecision = .backgroundTab
            _ = try await probe.evaluate("document.querySelector(\"#open\").click()", userGesture: true)
            do {
                try await probe.until("the popup tab") { !probe.popupTabs.isEmpty }
            } catch {
                let popups = probe.events.filter { if case .popupRequested = $0 { true } else { false } }.count
                throw E2EError("\(error) (decisions=\(probe.popupRequests.count) windowPopups=\(popups))")
            }
            let popup = probe.popupTabs[0]
            _ = try await popup.waitForLoad(1)
            return try await popup.evaluate("window.opener !== null") as? Bool ?? false
        }
        let request = probe.popupRequests.first
        let popupPassed =
            probe.popupRequests.count == 1 && request?.targetURL?.lastPathComponent == "opened.html"
            && request?.isUserGesture == true && opener
        run.check(
            "engine.popup", passed: popupPassed,
            "requests=\(probe.popupRequests.count) target=\(request?.targetURL?.lastPathComponent ?? "none") "
                + "disposition=\(request.map { "\($0.disposition)" } ?? "none") opener=\(opener ? "kept" : "lost")")

        // Key presses reach the app before the page: Command+K is claimed, a plain J is offered and left to the page.
        // A probe tab has no window and so no keyboard focus, so the page itself sees neither.
        try await run.step("claim a key before the page", timeout: E2ETimeouts.step) {
            probe.claimsKey = { $0.modifiers.contains(.command) && $0.keyCode == 40 }
            try await probe.pressKey("k", keyCode: 75, macKeyCode: 40, command: true)
            try await probe.pressKey("j", keyCode: 74, macKeyCode: 38)
            try await probe.until("the J key before the page") { probe.keyEvents.contains { $0.keyCode == 38 } }
        }
        let claimedDown = probe.claimedKeys.contains { $0.kind == .keyDown && $0.keyCode == 40 }
        let jClaimed = probe.claimedKeys.contains { $0.keyCode == 38 }
        let offered = probe.keyEvents.map { "\($0.kind):\($0.keyCode):\($0.modifiers.rawValue)" }
        run.check(
            "engine.key", passed: claimedDown && !jClaimed,
            "claimed=\(probe.claimedKeys.count) offered=\(offered.joined(separator: ","))")

        // Zoom set in one tab applies to its site, so a second tab on the same site opens zoomed.
        let zoom = try await run.step("zoom a site", timeout: E2ETimeouts.step * 2) {
            let before = probe.loads.count
            probe.tab.load(E2EFixture.url("engine/index.html"))
            _ = try await probe.waitForLoad(before + 1)
            probe.tab.setZoomLevel(1)
            try await probe.until("the zoom level") { probe.tab.zoomLevel == 1 }
            let second = try E2EEngineProbe.open(E2EFixture.url("engine/opened.html"), in: profile)
            track(second)
            _ = try await second.waitForLoad(1)
            try await second.until("the second tab's zoom") { second.tab.zoomLevel == 1 }
            return (probe.tab.zoomLevel, second)
        }
        run.check(
            "engine.zoom", passed: zoom.0 == 1 && zoom.1.tab.zoomLevel == 1,
            "first=\(zoom.0) second=\(zoom.1.tab.zoomLevel)")

        // Unloading frees the page and reports `unloaded`, never `closed`.
        let unloaded = try await run.step("unload a tab", timeout: E2ETimeouts.step) {
            await zoom.1.tab.unload()
        }
        let last = zoom.1.events.last
        run.check(
            "engine.unload",
            passed: unloaded && zoom.1.tab.isClosed && last == .unloaded
                && !zoom.1.events.contains(.closed),
            "unloaded=\(unloaded) closed=\(zoom.1.tab.isClosed) last=\(last.map { "\($0)" } ?? "none")")
    }
}
