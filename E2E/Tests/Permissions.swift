import AppKit
import Foundation

/// Tests of permission prompts: a page asking for the camera gets the app's own prompt, and the answer is
/// remembered per site and per profile. Chromium's fake camera answers, so no macOS privacy prompt shows.
/// Fixtures in E2E/Fixtures/permissions/.
@MainActor
enum PermissionsTests {
    static let all: [any E2ETest] = [PermissionsPromptTest()]
}

/// Asks for the camera in the default profile, allows it at the prompt and checks the page gets a live track; asks
/// again and checks the answer is remembered (no prompt, granted, and Chromium's own permission state agrees);
/// then asks in a new in-memory profile, which prompts again, blocks it and checks the page is refused.
struct PermissionsPromptTest: E2ETest {
    let name = "permissions.prompt"
    let checks = ["permissions.prompt", "permissions.remembered", "permissions.block"]

    func run(_ run: E2ERun) async throws {
        let url = E2EFixture.url("permissions/index.html")
        let page = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            // The app's default profile, whose answers are saved to disk (each test's own profile is in memory).
            let page = try await run.app.openWindow(at: url, profile: .appDefault)
            _ = try await page.waitForLoad(after: 0)
            return page
        }

        let prompt = try await run.step("prompt for the camera", timeout: E2ETimeouts.step) {
            _ = try await page.evaluate("startCamera()")
            return try await page.waitForPermissionPrompt()
        }
        try Self.checkOffScreen(prompt)
        let asked = prompt.kinds == ["camera"] && prompt.message == "bow.test wants to use your camera"
        let granted = try await run.step("allow", timeout: E2ETimeouts.step) {
            try prompt.answer(true)
            return try await page.string("window.cameraResult")
        }
        run.check(
            name,
            passed: asked && granted == "granted",
            "camera=\(asked ? "asked" : "kinds \(prompt.kinds.sorted()) \"\(prompt.message)\"") allow=\(granted)"
        )

        try await run.step("remembered", timeout: E2ETimeouts.step) {
            let second = try await page.string("requestCamera()")
            let shown = page.permissionPrompt != nil
            let query = try await page.string(
                "navigator.permissions.query({name: 'camera'}).then((status) => status.state)")
            let file = run.dataDirectory.appendingPathComponent("Permissions/Default.json")
            let saved = (try? String(contentsOf: file, encoding: .utf8))?.contains("\"https://bow.test\"") == true
            run.check(
                "permissions.remembered",
                passed: second == "granted" && !shown && query == "granted" && saved,
                "second=\(second) prompt=\(shown ? "shown" : "none") setting=\(query) saved=\(saved)"
            )
        }

        let other = try await run.step("open in a new profile", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(
                at: url, newProfile: E2EProfile(id: "e2e-permissions", isPersistent: false))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let otherPrompt = try await run.step("prompt in the new profile", timeout: E2ETimeouts.step) {
            _ = try await other.evaluate("startCamera()")
            return try await other.waitForPermissionPrompt()
        }
        try Self.checkOffScreen(otherPrompt)
        try await run.step("block", timeout: E2ETimeouts.step) {
            try otherPrompt.answer(false)
            let blocked = try await other.string("window.cameraResult")
            let again = try await other.string("requestCamera()")
            run.check(
                "permissions.block",
                passed: blocked == "NotAllowedError" && again == "NotAllowedError" && other.permissionPrompt == nil,
                "profile=asked block=\(blocked) again=\(again)"
            )
        }
    }

    /// The prompt is a window of its own; like the browser window, it must never show on a screen.
    private static func checkOffScreen(_ prompt: E2EPermissionPrompt) throws {
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(prompt.frame) }) {
            throw E2EError("the permission prompt at \(prompt.frame) shows on screen \(screen.frame)")
        }
    }
}
