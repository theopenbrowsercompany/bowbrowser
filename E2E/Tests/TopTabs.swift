import Foundation

/// The top tabs layout: View > Use Top Tabs switches the window between the sidebar and the compact top tabs layout,
/// with the toolbar row's measurements, the URL field, the Space dots, Cmd+L and a window opened while it is on.
/// Fixtures are the chrome area's pages (E2E/Fixtures/chrome/).
@MainActor
enum TopTabsTests {
    static let all: [any E2ETest] = [TopTabsLayoutTest(), TopTabStripTest()]

    static func app(_ run: E2ERun) throws -> any E2ETopTabsApp {
        guard let app = run.app as? any E2ETopTabsApp else { throw E2EError("the app has no top tabs hooks") }
        return app
    }

    static func url(_ name: String) -> URL { E2EFixture.url("chrome/\(name).html") }

    /// Waits until `condition` holds, or the step's wait budget runs out, and returns whether it held.
    static func until(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(E2EWaits.budget())
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try condition()
    }
}

/// The setting switches the layout and is saved, the toolbar row has the mockup's measurements and items, the URL
/// field and Space dots work, Cmd+L still opens the command bar, a new window follows the setting, and switching back
/// restores the sidebar as it was.
struct TopTabsLayoutTest: E2ETest {
    let name = "toptabs"
    let tags = ["smoke"]
    let checks = [
        "toptabs.default", "toptabs.setting", "toptabs.toolbar", "toptabs.url", "toptabs.spaces", "toptabs.cmd-l",
        "toptabs.new-window", "toptabs.restore",
    ]

    func run(_ run: E2ERun) async throws {
        let app = try TopTabsTests.app(run)
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace("work", today: [.tab("Page", url: TopTabsTests.url("page"))]),
                E2ESeedSpace("personal", today: [.tab("Keys", url: TopTabsTests.url("keys"))]),
            ], activeSpace: "work")
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let before = try await run.step("read the sidebar layout", timeout: E2ETimeouts.step) {
            _ = try await TopTabsTests.until { try app.spaces(of: page).tabs == ["Page"] }
            return (try app.topTabs(of: page), try app.spaces(of: page))
        }
        let initial = before.0
        run.check(
            "toptabs.default",
            passed: initial.saved == nil && !initial.menuChecked && initial.menuTitle == "Use Top Tabs"
                && !initial.sidebarHidden && initial.sidebarMinX == 0 && !initial.barShown
                && initial.pageInsets == [8, 264, 8, 8],
            "\(initial)")

        let top = try await run.step("choose Use Top Tabs", timeout: E2ETimeouts.step) {
            try app.chooseUseTopTabs(in: page)
            _ = try await TopTabsTests.until {
                let state = try app.topTabs(of: page)
                return state.sidebarHidden && state.barShown && state.urlText == "bow.test/chrome/page.html"
            }
            return try app.topTabs(of: page)
        }
        run.check(
            "toptabs.setting",
            passed: top.saved == "topTabs" && top.menuChecked && top.sidebarHidden && top.sidebarMinX < 0
                && top.barShown,
            "\(top)")

        let names = ["back", "forward", "reload", "url", "dots"]
        let frames = names.compactMap { top.items[$0] }
        var gaps: [Double] = []
        for (a, b) in zip(frames, frames.dropFirst()) { gaps.append(b.x - a.maxX) }
        // Buttons are 24 points wide and the gap between the items is 14.
        let rowItems = frames.count == names.count && gaps.allSatisfy { abs($0 - 14) <= 0.5 }
        let toolbarTop = top.stripHeight
        let centered = frames.allSatisfy { frame in
            abs((frame.y + frame.height / 2) - (toolbarTop + top.toolbarHeight / 2)) <= 1.5
        }
        let urlFrame = top.items["url"]
        run.check(
            "toptabs.toolbar",
            passed: top.stripHeight == 46 && top.toolbarHeight == 44 && rowItems && centered
                && abs(top.leadingPadding - 14) <= 0.5 && abs(top.trailingPadding - 14) <= 0.5
                && urlFrame?.height == 32 && top.urlRadius == 10 && top.urlFill == "#FFFFFF"
                && top.navigationTint == "#7A5A48" && top.pageInsets == [90, 8, 8, 8] && top.pageRadius == 10
                && abs(top.closeButtonX - 14) <= 0.5 && abs(top.closeButtonMidY - 23) <= 1.5,
            "gaps=\(gaps) centered=\(centered) \(top)")

        run.check(
            "toptabs.url", passed: top.urlText == "bow.test/chrome/page.html" && (urlFrame?.width ?? 0) > 100,
            "url=\"\(top.urlText)\" width=\(urlFrame?.width ?? 0)")

        if let design = run.app as? any E2EDesignApp {
            let folder = run.dataDirectory.deletingLastPathComponent().appendingPathComponent("toptabs")
            try await run.step("screenshot the top layout", timeout: E2ETimeouts.step) {
                try await design.writeScreenshot(of: page, to: folder.appendingPathComponent("top-tabs.png"))
            }
        }

        let switched = try await run.step("click the second Space dot", timeout: E2ETimeouts.step) {
            let first = try app.topTabs(of: page)
            try app.clickTopSpaceDot(1, in: page)
            _ = try await TopTabsTests.until {
                let state = try app.topTabs(of: page)
                return try app.spaces(of: page).active == "personal" && state.activeDotName == "personal"
                    && state.urlText == "bow.test/chrome/keys.html"
            }
            return (first, try app.topTabs(of: page), try app.spaces(of: page))
        }
        run.check(
            "toptabs.spaces",
            passed: switched.0.dotCount == 2 && switched.0.activeDotName == "work" && switched.0.activeDotRing == 2
                && switched.0.dotSize == 14 && switched.1.activeDotName == "personal"
                && switched.1.activeDotRing == 2 && switched.2.active == "personal"
                && switched.1.urlText == "bow.test/chrome/keys.html",
            "before: \(switched.0) after: \(switched.1) spaces: \(switched.2)")

        let location = try await run.step("Cmd+L in the top layout", timeout: E2ETimeouts.step) {
            try app.chooseMenuItem(key: "l", modifiers: .command, in: page)
            let bar = try app.commandBar(of: page)
            let opened = try await TopTabsTests.until { bar.isShown && bar.hasKeyboard }
            let text = bar.text
            try bar.press(.escape)
            _ = try await TopTabsTests.until { !bar.isShown }
            return (opened, text)
        }
        run.check(
            "toptabs.cmd-l", passed: location.0 && location.1 == TopTabsTests.url("keys").absoluteString,
            "opened=\(location.0) text=\(location.1)")

        let second = try await run.step("open a window with the setting on", timeout: E2ETimeouts.firstLoad) {
            let other = try await app.openWindow(at: TopTabsTests.url("page"))
            _ = try await other.waitForLoad(after: 0)
            _ = try await TopTabsTests.until { try app.topTabs(of: other).barShown }
            return try app.topTabs(of: other)
        }
        run.check(
            "toptabs.new-window",
            passed: second.sidebarHidden && second.barShown && second.pageInsets == [90, 8, 8, 8]
                && second.items.count == 5 && abs(second.leadingPadding - 14) <= 0.5
                && (second.items["back"]?.y ?? 0) >= 46 && second.urlText == "bow.test/chrome/page.html",
            "\(second)")

        let preRestore = try app.spaces(of: page)
        let restored = try await run.step("choose Use Top Tabs again", timeout: E2ETimeouts.step) {
            try app.chooseUseTopTabs(in: page)
            _ = try await TopTabsTests.until {
                let state = try app.topTabs(of: page)
                return !state.sidebarHidden && !state.barShown
            }
            return (try app.topTabs(of: page), try app.spaces(of: page))
        }
        let state = restored.0
        let back = state.items["back"]
        // The sidebar's Space header is only drawn while the sidebar shows, so it is compared after the restore.
        let same =
            restored.1.spaces == preRestore.spaces && restored.1.active == preRestore.active
            && restored.1.tabs == preRestore.tabs && restored.1.footer == preRestore.footer
            && restored.1.header == preRestore.active
        run.check(
            "toptabs.restore",
            passed: state.saved == "sidebar" && !state.menuChecked && !state.sidebarHidden && state.sidebarMinX == 0
                && !state.barShown && state.pageInsets == [8, 264, 8, 8] && same
                && (back?.maxX ?? 999) <= 264,
            "\(state) spaces=\(restored.1) before=\(preRestore)")
    }
}
