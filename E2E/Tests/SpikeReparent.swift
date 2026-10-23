import AppKit

/// Spike S1 (throwaway branch): moves one live tab, with a playing video and a half filled form, between a window,
/// a floating panel and a second window, and checks after every move that nothing reloaded and the page still
/// works: form state, media, rendering, size, renderer focus, native first responder, native IME, native right
/// click coordinates, and NotifyScreenInfoChanged. Fixture in E2E/Fixtures/reparent/.
@MainActor
enum SpikeReparentTests {
    static let all: [any E2ETest] = [SpikeReparentTest()]
}

struct SpikeReparentTest: E2ETest {
    let name = "spike.reparent"

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? E2EAppAdapter else { throw E2EError("the app is not the adapter") }
        let page = try await run.step("open window A", timeout: E2ETimeouts.step) {
            try await app.openWindow(at: E2EFixture.url("reparent/index.html"))
        }
        try await run.step("load", timeout: E2ETimeouts.firstLoad) {
            let status = try await page.waitForLoad(after: 0)
            guard status == 200 else { throw E2EError("loaded with status \(status)") }
        }
        let tabID = try app.spikeTabID(of: page)
        let hostA = try app.spikeWindowHost(of: page)

        // Half fill the form: name typed, plan and checkbox set, notes left empty.
        let baseline = try await run.step("fill form and play", timeout: E2ETimeouts.step) {
            try await page.click("#name")
            try await page.type("Ada half filled")
            try await page.click("#agree")
            _ = try await page.evaluate("(() => { const s = document.querySelector('#plan'); s.value = 'pro'; s.dispatchEvent(new Event('change')); })()")
            try await page.click("#name")
            try await E2EWaits.until(page, "video.readyState >= 3 && !video.paused && video.getVideoPlaybackQuality().totalVideoFrames > 10")
            return Baseline(
                loadID: try await page.string("window.bowLoadID"),
                engineLoads: page.finishedLoads,
                form: try await Self.form(page),
                media: try await page.string("JSON.stringify(bowMedia)")
            )
        }

        let other = try await run.step("open window B", timeout: E2ETimeouts.firstLoad) {
            let other = try await app.openWindow(at: E2EFixture.url("tabs/counter.html?name=b"))
            _ = try await other.waitForLoad(after: 0)
            return other
        }
        let hostB = try app.spikeWindowHost(of: other)
        let panel = try await run.step("open panel", timeout: E2ETimeouts.step) { try await app.spikeOpenPanel() }

        let moves: [(String, BowWebView)] = [
            ("window-to-panel", panel), ("panel-to-window", hostA), ("window-to-window", hostB),
            ("window-to-panel-2", panel), ("panel-to-window-2", hostA),
        ]
        var expectedActive = "name"
        for (index, (label, host)) in moves.enumerated() {
            let results = try await run.step("move \(label)", timeout: E2ETimeouts.step * 2) {
                try await Self.moveAndCheck(
                    page: page, app: app, tabID: tabID, host: host, index: index, baseline: baseline,
                    expectedActive: expectedActive)
            }
            expectedActive = "notes"  // the right click focuses #notes last
            for (check, problem) in results {
                run.check("spike.reparent.\(label).\(check)", passed: problem.hasPrefix("ok"), problem)
            }
        }

        // The windows and panel the tab passed through close while it lives on in window A.
        try await run.step("close panel and window B", timeout: E2ETimeouts.step) {
            SpikeStorage.panels.forEach { $0.close() }
            SpikeStorage.panels.removeAll()
            try await app.closeWindow(of: other)
            try await E2EWaits.untilRendering(page)
            let same = try await page.string("window.bowLoadID") == baseline.loadID
            let form = try await Self.form(page)
            let frames = try await page.evaluate("video.getVideoPlaybackQuality().totalVideoFrames") as? Int ?? 0
            try await E2EWaits.until(page, "video.getVideoPlaybackQuality().totalVideoFrames > \(frames + 10)")
            let ok = same && form == baseline.form && !page.isClosed && page.finishedLoads == baseline.engineLoads
            run.check(
                "spike.reparent.close-previous-hosts", passed: ok,
                ok ? "ok tab alive in window A, same document, form kept, video playing" : "same=\(same) form=\(form)")
        }
    }

    struct Baseline {
        var loadID: String
        var engineLoads: Int
        var form: String
        var media: String
    }

    static func form(_ page: any E2EPage) async throws -> String {
        try await page.string(
            "JSON.stringify([document.getElementById('name').value, notes.value, plan.value, agree.checked])")
    }

    static func findWidgetView(_ view: NSView) -> NSView? {
        if NSStringFromClass(type(of: view)).contains("RenderWidgetHostViewCocoa") { return view }
        for subview in view.subviews {
            if let found = findWidgetView(subview) { return found }
        }
        return nil
    }

    /// Moves the tab into `host` and returns one (check, "ok ..." or problem) pair per property.
    static func moveAndCheck(
        page: any E2EPage, app: E2EAppAdapter, tabID: UInt64, host: BowWebView, index: Int, baseline: Baseline,
        expectedActive: String
    ) async throws -> [(String, String)] {
        let framesBefore = try await page.evaluate("video.getVideoPlaybackQuality().totalVideoFrames") as? Int ?? 0
        let start = Date()
        try app.spikeMove(page, to: host)
        let moveSeconds = Date().timeIntervalSince(start)
        var results: [(String, String)] = []

        // No reload: same document, no new engine load, page load counter still 1.
        let sameDocument = try await page.string("window.bowLoadID") == baseline.loadID
        let pageLoads = try await page.string("sessionStorage.getItem('loads')")
        let loads = page.finishedLoads
        results.append((
            "no-reload",
            sameDocument && pageLoads == "1" && loads == baseline.engineLoads
                ? "ok same document, loads=\(loads), move took \(String(format: "%.3f", moveSeconds))s"
                : "sameDocument=\(sameDocument) pageLoads=\(pageLoads) engineLoads=\(loads)"
        ))

        let form = try await form(page)
        results.append(("form", form == baseline.form ? "ok \(form)" : "form \(form), was \(baseline.form)"))

        // Visible and painting, and laid out at the new host's size.
        do {
            try await E2EWaits.untilRendering(page)
            let width = try await page.evaluate("innerWidth") as? Int ?? -1
            let height = try await page.evaluate("innerHeight") as? Int ?? -1
            let want = host.bounds.size
            let sized = width == Int(want.width) && height == Int(want.height)
            results.append((
                "render", sized ? "ok visible, painting, \(width)x\(height)" : "viewport \(width)x\(height), host \(want)"
            ))
        } catch {
            results.append(("render", "\(error)"))
        }

        // Media keeps playing on the same element and pipeline.
        do {
            try await E2EWaits.until(
                page, "!video.paused && video.getVideoPlaybackQuality().totalVideoFrames > \(framesBefore + 15)")
            let media = try await page.string("JSON.stringify(bowMedia)")
            let frames = try await page.evaluate("video.getVideoPlaybackQuality().totalVideoFrames") as? Int ?? 0
            results.append((
                "media",
                media == baseline.media
                    ? "ok playing, frames \(framesBefore) to \(frames), events \(media)"
                    : "media events changed: \(media), was \(baseline.media)"
            ))
        } catch {
            results.append(("media", "\(error)"))
        }

        // Renderer focus: the focused element survives the move.
        let active = try await page.string("document.activeElement.id")
        results.append(("dom-focus", active == expectedActive ? "ok activeElement=\(active)" : "activeElement=\(active), want \(expectedActive)"))

        // Native focus: the new window can make Chromium's widget view its first responder, and CEF SetFocus works.
        guard let browserView = BowSpikeReparent.browserView(forTabID: tabID),
            let widget = findWidgetView(browserView), let window = widget.window
        else {
            results.append(("native", "no widget view or window"))
            return results
        }
        let inHost = browserView.superview === host && window === host.window
        let madeFirst = window.makeFirstResponder(widget)
        let setFocus = BowSpikeReparent.setFocus(true, forTabID: tabID)
        results.append((
            "first-responder",
            inHost && madeFirst && window.firstResponder === widget && setFocus
                ? "ok widget is first responder of \(type(of: window))"
                : "inHost=\(inHost) made=\(madeFirst) first=\(String(describing: window.firstResponder)) setFocus=\(setFocus)"
        ))

        // Native IME through NSTextInputClient on the widget view, as an input method would drive it.
        do {
            try await page.click("#ime")
            _ = window.makeFirstResponder(widget)
            guard let client = widget as? NSTextInputClient else { throw E2EError("widget is not an NSTextInputClient") }
            _ = try await page.evaluate("bowEvents.composition = []")
            let none = NSRange(location: NSNotFound, length: 0)
            client.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            let marked = client.hasMarkedText()
            client.insertText("漢\(index)", replacementRange: none)
            try await E2EWaits.until(page, "document.querySelector('#ime').value.endsWith('漢\(index)')")
            let events = try await page.string("bowEvents.composition.join(',')")
            results.append(("ime", "ok marked=\(marked) value ends with 漢\(index), events \(events)"))
        } catch {
            let value = (try? await page.string("document.querySelector('#ime').value")) ?? "?"
            results.append(("ime", "\(error) (ime value \"\(value)\")"))
        }

        // Native right click: an NSEvent in the new window's coordinates reaches the page at the right point.
        do {
            let rect = try await page.evaluate(
                "(() => { const r = notes.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
            ) as? [Double] ?? []
            guard rect.count == 2 else { throw E2EError("no rect for #notes") }
            let local = NSPoint(x: rect[0], y: widget.isFlipped ? rect[1] : widget.bounds.height - rect[1])
            let inWindow = widget.convert(local, to: nil)
            let before = try await page.evaluate("bowEvents.contextmenu.length") as? Int ?? 0
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { throw E2EError("no event") }
                if type == .rightMouseDown { widget.rightMouseDown(with: event) } else { widget.rightMouseUp(with: event) }
            }
            try await E2EWaits.until(page, "bowEvents.contextmenu.length > \(before)")
            let got = try await page.evaluate(
                "(() => { const e = bowEvents.contextmenu.at(-1); return [e.x, e.y, e.target]; })()") as? [Any] ?? []
            let x = got.first as? Double ?? -1, y = got.count > 1 ? got[1] as? Double ?? -1 : -1
            let target = got.count > 2 ? got[2] as? String ?? "" : ""
            let close = abs(x - rect[0]) <= 2 && abs(y - rect[1]) <= 2 && target == "notes"
            results.append((
                "context-menu-event",
                close ? "ok at \(x),\(y) on #\(target)" : "landed at \(x),\(y) on \(target), want \(rect)"
            ))
        } catch {
            results.append(("context-menu-event", "\(error)"))
        }

        // NotifyScreenInfoChanged after the move: accepted, and the page stays the same live document.
        let notified = BowSpikeReparent.notifyScreenInfoChanged(forTabID: tabID)
        let dpr = try await page.evaluate("devicePixelRatio") as? Double ?? -1
        let stillSame = try await page.string("window.bowLoadID") == baseline.loadID
        let backing = window.backingScaleFactor
        results.append((
            "screen-info",
            notified && stillSame && dpr == Double(backing)
                ? "ok notified, devicePixelRatio=\(dpr) matches backing \(backing)"
                : "notified=\(notified) same=\(stillSame) dpr=\(dpr) backing=\(backing)"
        ))
        return results
    }
}
