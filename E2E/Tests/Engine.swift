import BowCore
import Foundation

/// Tests that each engine hook reaches the app: the popup decision, keys before the page, per site zoom, unload and
/// why a tab closed. They drive engine tabs with no window (`E2EEngineProbe`), since the window answers these hooks
/// with their defaults until the features that use them land. Fixtures in E2E/Fixtures/engine/.
@MainActor
enum EngineTests {
    static let all: [any E2ETest] = [
        EngineHooksTest(), EngineChallengesTest(), EngineWatchdogTest(loop: .tracking),
        EngineWatchdogTest(loop: .defaultMode),
    ]
}

/// The watchdog's self tests: a step gets the main thread stuck in a nested run loop that never ends
/// (`E2ENestedLoop`), and the run must end with `E2E: TIMEOUT <test>: <step>`, a stack sample in hang.txt and exit
/// code 2 within the watchdog's limit. Each ends its run, so it runs only when named exactly (`selectedByNameOnly`):
/// `make e2e E2E=engine.watchdog-tracking-loop` or `E2E=engine.watchdog-default-mode-loop`.
/// The names are the loop's raw values rather than a stored name set to a string literal, the form `make done`
/// reads to repeat changed tests, so its repeat step never reruns a test whose pass is a TIMEOUT.
struct EngineWatchdogTest: E2ETest {
    enum Loop: String {
        case tracking = "engine.watchdog-tracking-loop"
        case defaultMode = "engine.watchdog-default-mode-loop"
    }

    let loop: Loop
    var name: String { loop.rawValue }
    var selectedByNameOnly: Bool { true }

    func run(_ run: E2ERun) async throws {
        let step =
            loop == .tracking ? "enter a tracking loop with no mouseUp" : "spin the run loop in its default mode"
        try await run.step(step, timeout: E2ETimeouts.step) { () -> Void in
            switch loop {
            case .tracking: E2ENestedLoop.trackWithoutMouseUp()
            case .defaultMode: E2ENestedLoop.spinDefaultMode()
            }
        }
        run.check(name, passed: false, "the nested run loop returned, which it never should")
    }
}

/// Opens a probe tab on the fixture and walks it through every hook, one check each.
struct EngineHooksTest: E2ETest {
    let name = "engine.hooks"
    let tags = ["smoke"]
    let checks = ["engine.popup", "engine.key", "engine.zoom", "engine.unload", "engine.close-reason"]

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
        try await popup(run, probe: probe)
        try await keys(run, probe: probe)
        let second = try await zoom(run, probe: probe, profile: profile, track: track)
        try await unload(run, unloading: second, profile: profile, track: track)
        try await selfClose(run, probe: probe)
    }

    /// A page's window.open from a click is decided by the app, which asks for a background tab: the page arrives as
    /// a tab of its own, still connected to its opener, and handed over before its first navigation, which its new
    /// owner decides.
    private func popup(_ run: E2ERun, probe: E2EEngineProbe) async throws {
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
        let firstNavigation = probe.popupTabs.first?.navigations.first?.lastPathComponent ?? "none"
        let passed =
            probe.popupRequests.count == 1 && request?.targetURL?.lastPathComponent == "opened.html"
            && request?.disposition == .foregroundTab && request?.isUserGesture == true && opener
            && firstNavigation == "opened.html"
        run.check(
            "engine.popup", passed: passed,
            "requests=\(probe.popupRequests.count) target=\(request?.targetURL?.lastPathComponent ?? "none") "
                + "disposition=\(request.map { "\($0.disposition)" } ?? "none") opener=\(opener ? "kept" : "lost") "
                + "first-navigation=\(firstNavigation)")
    }

    /// Key presses reach the app before the page: Command+K is claimed, so neither its key down nor its key up
    /// reaches the page, and its key up is not offered again; a plain J is offered and left to the page. The probe
    /// emulates focus, so the page receives the keys it is left. A hidden page may drop the first keys after its
    /// focus changes, so J is pressed until the page has seen one before Command+K, and the J pressed after
    /// Command+K reaching the page shows the page was receiving keys while Command+K was claimed.
    private func keys(_ run: E2ERun, probe: E2EEngineProbe) async throws {
        let page = try await run.step("claim a key before the page", timeout: E2ETimeouts.step) {
            try await probe.focusPage()
            var keys: (down: [String], up: [String]) = ([], [])
            let readKeys = {
                keys.down = try await probe.evaluate("window.keyDowns") as? [String] ?? []
                keys.up = try await probe.evaluate("window.keyUps") as? [String] ?? []
            }
            try await probe.until("a J key in the page") {
                keys.down.contains("j") && keys.up.contains("j")
            } refresh: {
                try await probe.pressKey("j", keyCode: 74, macKeyCode: 38)
                try await readKeys()
            }
            let seen = (down: keys.down.count, up: keys.up.count)
            probe.claimsKey = { $0.modifiers.contains(.command) && $0.keyCode == 40 }
            try await probe.pressKey("k", keyCode: 75, macKeyCode: 40, command: true)
            try await probe.pressKey("j", keyCode: 74, macKeyCode: 38)
            try await probe.until("the J key after Command+K in the page") {
                keys.down.count > seen.down && keys.up.count > seen.up
            } refresh: {
                try await readKeys()
            }
            return keys
        }
        let claimedDown = probe.claimedKeys.contains { $0.kind == .keyDown && $0.keyCode == 40 }
        let claimedUpOffered = probe.keyEvents.contains { $0.kind == .keyUp && $0.keyCode == 40 }
        let jClaimed = probe.claimedKeys.contains { $0.keyCode == 38 }
        let pageSawK = (page.down + page.up).contains { $0.lowercased() == "k" }
        let offered = probe.keyEvents.map { "\($0.kind):\($0.keyCode):\($0.modifiers.rawValue)" }
        run.check(
            "engine.key",
            passed: claimedDown && !claimedUpOffered && !jClaimed && page.down.contains("j") && !pageSawK,
            "claimed=\(probe.claimedKeys.count) offered=\(offered.joined(separator: ",")) "
                + "page-down=\(page.down.joined(separator: ",")) page-up=\(page.up.joined(separator: ","))")
    }

    /// Zoom set in one tab applies to its site, so a second tab on the same site opens zoomed. Returns that tab.
    private func zoom(
        _ run: E2ERun, probe: E2EEngineProbe, profile: any EngineProfile, track: @escaping (E2EEngineProbe) -> Void
    ) async throws -> E2EEngineProbe {
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
        return zoom.1
    }

    /// Unloading frees the page and reports `unloaded`, never `closed`. A close asked for while an unload is still
    /// pending (its page's beforeunload still running) takes it over: the unload answers false and the
    /// tab's last event is `closed`, by the app.
    private func unload(
        _ run: E2ERun, unloading tab: E2EEngineProbe, profile: any EngineProfile,
        track: @escaping (E2EEngineProbe) -> Void
    ) async throws {
        let result = try await run.step("unload a tab", timeout: E2ETimeouts.step * 2) {
            let unloaded = await tab.tab.unload()
            let third = try E2EEngineProbe.open(E2EFixture.url("engine/slow-unload.html"), in: profile)
            track(third)
            _ = try await third.waitForLoad(1)
            // The page's beforeunload keeps it busy for 300 ms, so the close arrives while the unload is pending.
            let takenOver = Task { await third.tab.unload() }
            try await Task.sleep(nanoseconds: 50_000_000)
            let closed = Task { await third.tab.close() }
            let (unload, close) = (await takenOver.value, await closed.value)
            try await third.until("the closed event") { third.events.last == .closed }
            return (unloaded: unloaded, third: third, takenOver: unload, closed: close)
        }
        let last = tab.events.last.map { "\($0)" } ?? "none"
        let third = result.third
        let thirdLast = third.events.last.map { "\($0)" } ?? "none"
        let unloadPassed =
            result.unloaded && tab.tab.isClosed && tab.events.last == .unloaded && !tab.events.contains(.closed)
            && tab.tab.closeReason == nil
        let takeOverPassed =
            !result.takenOver && result.closed && third.events.last == .closed && !third.events.contains(.unloaded)
            && third.tab.closeReason == .app
        run.check(
            "engine.unload", passed: unloadPassed && takeOverPassed,
            "unloaded=\(result.unloaded) closed=\(tab.tab.isClosed) last=\(last) "
                + "taken-over-unload=\(result.takenOver) close=\(result.closed) close-last=\(thirdLast) "
                + "close-reason=\(third.tab.closeReason.map { "\($0)" } ?? "none")")
    }

    /// A page that closes itself (window.close() in the popup its opener's script opened) says so: the tab's last
    /// event is `closed`, with the reason `.page`, and it can no longer be unloaded.
    private func selfClose(_ run: E2ERun, probe: E2EEngineProbe) async throws {
        let result = try await run.step("a page closes itself", timeout: E2ETimeouts.step) {
            guard let popup = probe.popupTabs.first else { throw E2EError("no popup tab to close") }
            _ = try await popup.evaluate("setTimeout(() => window.close(), 0); true")
            try await popup.until("the popup's closed event") { popup.events.last == .closed }
            return (popup: popup, unloaded: await popup.tab.unload())
        }
        let reason = result.popup.tab.closeReason
        run.check(
            "engine.close-reason", passed: reason == .page && !result.unloaded,
            "reason=\(reason.map { "\($0)" } ?? "none") unload-after-close=\(result.unloaded)")
    }
}

/// A load's questions reach the window: a 401 with a Basic challenge from the loopback sign in fixture asks the
/// window for a user name and password, and a self-signed certificate from the loopback TLS fixture asks it whether
/// to go on. Both are answered with cancel (the sign in sheet's Cancel, and the certificate error page never goes
/// on), so the 401 page shows and the certificate load fails, and neither fixture sees a request that got past its
/// question. The auth area tests the sheet and the page themselves.
struct EngineChallengesTest: E2ETest {
    let name = "engine.challenges"
    let checks = ["engine.auth_hook", "engine.cert_hook"]

    func run(_ run: E2ERun) async throws {
        guard let challenges = run.app as? any E2EChallengesApp else {
            throw E2EError("the app cannot record challenges")
        }
        let fixtures = try E2ELoopback.running()
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: E2EFixture.url("engine/index.html"))
            _ = try await page.waitForLoad(after: 0)
            try challenges.recordChallenges(of: page)
            return page
        }

        let auth = try await run.step("load a page that asks to sign in", timeout: E2ETimeouts.firstLoad) {
            // The window's sign in sheet takes the question; Cancel answers it as no feature would.
            let ended = try await Self.load(E2ELoopback.authURL, in: page) {
                guard let sheets = run.app as? any E2EAuthApp else { throw E2EError("the app has no sign in sheet") }
                guard try await E2EWaits.until({ try sheets.signInSheet(besides: page) != nil }) else {
                    throw E2EError("no sign in sheet came up")
                }
                try sheets.answerSignInSheet(besides: page, user: nil, password: nil)
            }
            let title = ended.kind == .finish ? try await page.string("document.title") : ""
            return (ended: ended, questions: try challenges.authChallenges(of: page), title: title)
        }
        let question = auth.questions.first
        run.check(
            "engine.auth_hook",
            passed: auth.questions.count == 1 && question?.host == E2ELoopback.authHost && question?.realm == "bow"
                && question?.scheme.lowercased() == "basic" && question?.isProxy == false
                && question?.answered == true && question?.answeredUser == nil && auth.ended.kind == .finish
                && auth.ended.code == 401 && auth.title == "Sign in required" && fixtures.authorizedRequests == 0,
            "questions=\(auth.questions) ended=\(auth.ended) title=\(auth.title) "
                + "unauthorized=\(fixtures.unauthorizedRequests) authorized=\(fixtures.authorizedRequests)")

        let certificate = try await run.step("load a page with a bad certificate", timeout: E2ETimeouts.firstLoad) {
            _ = try E2ELoopback.runningWithCertificate()
            let ended = try await Self.load(E2ELoopback.badCertificateURL, in: page)
            return (ended: ended, questions: try challenges.certificateErrors(of: page))
        }
        let error = certificate.questions.first
        run.check(
            "engine.cert_hook",
            passed: certificate.questions.count == 1 && error?.url?.host == E2ELoopback.certificateHost
                && error?.code == -202 && error?.proceeded == false && certificate.ended.kind == .fail
                && certificate.ended.code == -202 && fixtures.certificateRequests == 0,
            "questions=\(certificate.questions) ended=\(certificate.ended) served=\(fixtures.certificateRequests)")
    }

    /// Loads `url` in `page`, runs `whileLoading` once the load has started, and returns the event its load ended
    /// with, finished or failed.
    private static func load(
        _ url: URL, in page: any E2EPage, whileLoading: () async throws -> Void = {}
    ) async throws -> E2ENavigationEvent {
        let before = page.finishedLoads
        let events = page.navigationEvents.count
        try page.load(url)
        try await whileLoading()
        do {
            _ = try await page.waitForLoad(after: before)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as E2EError where error.reason != nil {
            throw error
        } catch {
            // A failed load throws; its events say how it failed.
            guard page.finishedLoads > before else { throw error }
        }
        guard let ended = page.navigationEvents[events...].last(where: { $0.kind == .fail || $0.kind == .finish })
        else { throw E2EError("the load of \(url) ended without a finish or fail event") }
        return ended
    }
}
