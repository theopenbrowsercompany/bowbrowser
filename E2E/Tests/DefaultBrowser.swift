import AppKit
import BowCore
import Foundation

/// Tests of Bow > Set as Default Browser…, with the system's registration replaced by a recorder: the e2e build has no
/// real registrar, so the macOS setter is never called. Fixtures in E2E/Fixtures/app/.
@MainActor
enum DefaultBrowserTests {
    static let all: [any E2ETest] = [
        DefaultBrowserSetTest(),
        DefaultBrowserAlreadyTest(),
        DefaultBrowserFailureTest(),
    ]

    static func defaultApp(_ run: E2ERun) throws -> any E2EDefaultBrowserApp {
        guard let app = run.app as? any E2EDefaultBrowserApp else { throw E2EError("the app has no default browser") }
        return app
    }

    static func openWindow(_ run: E2ERun) async throws -> any E2EPage {
        try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            try await run.app.openWindow(at: E2EFixture.url("app/index.html"))
        }
    }

    /// The registrations a complete run asks for: http, then https, for the running app.
    static var expectedCalls: [String] {
        DefaultBrowser.schemes.map { "\($0) \(Bundle.main.bundleURL.path)" }
    }
}

/// Choosing Set as Default Browser… through the app menu asks the system to register http, then https, for Bow's
/// bundle, and the e2e build's blocked real setter is never reached. A second choice while the system's prompt is up is
/// refused (the item is disabled), so only one registration runs. Declining the system's prompt registers no https and
/// shows no alert.
struct DefaultBrowserSetTest: E2ETest {
    let name = "defaultbrowser"
    let checks = ["defaultbrowser", "defaultbrowser.twice", "defaultbrowser.cancel"]

    func run(_ run: E2ERun) async throws {
        let app = try DefaultBrowserTests.defaultApp(run)
        let page = try await DefaultBrowserTests.openWindow(run)
        defer { app.removeDefaultBrowserRecorder() }

        try await run.step("choose with no default", timeout: E2ETimeouts.step) {
            try app.installDefaultBrowserRecorder(handler: nil, failure: nil, holds: false, besides: page)
            let item = try app.defaultBrowserItem()
            try app.chooseSetAsDefaultBrowser(in: page)
            await app.waitForDefaultBrowserRegistration()
            let calls = app.defaultBrowserCalls
            run.check(
                "defaultbrowser",
                passed: item == E2EDefaultBrowserItem(title: DefaultBrowser.setTitle, enabled: true)
                    && calls == DefaultBrowserTests.expectedCalls && app.blockedDefaultBrowserCalls == 0,
                "item=\(item) calls=\(calls) blocked=\(app.blockedDefaultBrowserCalls)")
        }

        try await run.step("choose twice", timeout: E2ETimeouts.step) {
            try app.installDefaultBrowserRecorder(handler: nil, failure: nil, holds: true, besides: page)
            try app.chooseSetAsDefaultBrowser(in: page)
            let asked = try await E2EWaits.until { app.defaultBrowserCalls.count == 1 }
            let waiting = try app.defaultBrowserItem()
            var second = "not refused"
            do { try app.chooseSetAsDefaultBrowser(in: page) } catch { second = "\(error)" }
            app.releaseDefaultBrowserRegistration()
            await app.waitForDefaultBrowserRegistration()
            let calls = app.defaultBrowserCalls
            let after = try app.defaultBrowserItem()
            run.check(
                "defaultbrowser.twice",
                passed: asked && !waiting.enabled && second.contains("disabled")
                    && calls == DefaultBrowserTests.expectedCalls && after.enabled,
                "asked=\(asked) waiting=\(waiting) second=\(second) calls=\(calls) after=\(after)")
        }

        try await run.step("decline the prompt", timeout: E2ETimeouts.step) {
            let declined = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            try app.installDefaultBrowserRecorder(handler: nil, failure: declined, holds: false, besides: page)
            try app.chooseSetAsDefaultBrowser(in: page)
            await app.waitForDefaultBrowserRegistration()
            let calls = app.defaultBrowserCalls
            run.check(
                "defaultbrowser.cancel",
                passed: calls == [DefaultBrowserTests.expectedCalls[0]] && app.defaultBrowserAlert() == nil,
                "calls=\(calls) alert=\(app.defaultBrowserAlert().map { "\($0)" } ?? "none")")
        }
    }
}

/// With the system saying Bow opens http links, the item shows "Bow Is Your Default Browser", disabled, and choosing it
/// registers nothing.
struct DefaultBrowserAlreadyTest: E2ETest {
    let name = "defaultbrowser.already"
    let checks = ["defaultbrowser.already"]

    func run(_ run: E2ERun) async throws {
        let app = try DefaultBrowserTests.defaultApp(run)
        let page = try await DefaultBrowserTests.openWindow(run)
        defer { app.removeDefaultBrowserRecorder() }

        try await run.step("read the item", timeout: E2ETimeouts.step) {
            try app.installDefaultBrowserRecorder(
                handler: Bundle.main.bundleURL, failure: nil, holds: false, besides: page)
            let item = try app.defaultBrowserItem()
            var chosen = "not refused"
            do { try app.chooseSetAsDefaultBrowser(in: page) } catch { chosen = "\(error)" }
            run.check(
                "defaultbrowser.already",
                passed: item == E2EDefaultBrowserItem(title: DefaultBrowser.isDefaultTitle, enabled: false)
                    && chosen.contains("disabled") && app.defaultBrowserCalls.isEmpty
                    && app.blockedDefaultBrowserCalls == 0,
                "item=\(item) choose=\(chosen) calls=\(app.defaultBrowserCalls)")
        }
    }
}

/// When the system refuses, an alert sheet on the window says Bow could not be set, naming the scheme and the reason;
/// answering OK closes it, and https is not tried after http failed.
struct DefaultBrowserFailureTest: E2ETest {
    let name = "defaultbrowser.failure"
    let checks = ["defaultbrowser.failure"]

    func run(_ run: E2ERun) async throws {
        let app = try DefaultBrowserTests.defaultApp(run)
        let page = try await DefaultBrowserTests.openWindow(run)
        defer { app.removeDefaultBrowserRecorder() }

        try await run.step("refuse and answer the alert", timeout: E2ETimeouts.step) {
            let refusal = NSError(
                domain: "e2e", code: 7, userInfo: [NSLocalizedDescriptionKey: "The system refused."])
            try app.installDefaultBrowserRecorder(handler: nil, failure: refusal, holds: false, besides: page)
            try app.chooseSetAsDefaultBrowser(in: page)
            let shown = try await E2EWaits.until { app.defaultBrowserAlert() != nil }
            let alert = app.defaultBrowserAlert()
            if shown { try app.answerDefaultBrowserAlert() }
            await app.waitForDefaultBrowserRegistration()
            let calls = app.defaultBrowserCalls
            run.check(
                "defaultbrowser.failure",
                passed: shown && alert?.title == "Bow could not be set as your default browser"
                    && alert?.detail.contains("http") == true && alert?.detail.contains("The system refused.") == true
                    && alert?.buttons == ["OK"] && alert?.isAttached == true
                    && calls == [DefaultBrowserTests.expectedCalls[0]] && app.defaultBrowserAlert() == nil,
                "alert=\(alert.map { "\($0)" } ?? "none") calls=\(calls)")
        }
    }
}
