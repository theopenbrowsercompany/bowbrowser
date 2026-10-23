import Foundation

/// The top tabs layout's tab strip: the Space's today tabs as 190 by 32 pills with the shown tab's lifted, a click
/// that shows a tab, a close button on the shown pill and on hover, the + button opening the command bar, pills that
/// shrink and then scroll when crowded, and a strip that follows the Space on screen.
/// Fixtures are the chrome area's pages (E2E/Fixtures/chrome/).
struct TopTabStripTest: E2ETest {
    let name = "toptabs.strip"
    let tags: [String] = []
    let checks = [
        "toptabs.strip.pills", "toptabs.strip.active", "toptabs.strip.plus", "toptabs.strip.select",
        "toptabs.strip.close", "toptabs.strip.spaces", "toptabs.strip.crowded", "toptabs.strip.reveal",
        "toptabs.strip.shrink",
    ]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2ETabStripApp else { throw E2EError("the app has no tab strip hooks") }
        let crowd = (1...14).map { E2ESeedItem.tab("Crowd \($0)", url: TopTabsTests.url("page")) }
        let seed = E2ESeed(
            spaces: [
                E2ESeedSpace(
                    "work", pinned: [.tab("Pinned", url: TopTabsTests.url("keys"))],
                    today: [
                        .tab("A", url: TopTabsTests.url("page")), .tab("B", url: TopTabsTests.url("keys")),
                        .tab("C", url: TopTabsTests.url("page")),
                    ]),
                E2ESeedSpace("crowd", today: crowd),
            ], activeSpace: "work")
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let opened0 = try await run.step("choose Use Top Tabs", timeout: E2ETimeouts.step) {
            try app.chooseUseTopTabs(in: page)
            _ = try await TopTabsTests.until { try app.tabStrip(of: page).pills.count == 3 }
            return try app.tabStrip(of: page)
        }
        let sidebarTabs = try app.spaces(of: page).tabs
        let strip = opened0
        let gaps = zip(strip.pills, strip.pills.dropFirst()).map { $1.frame.x - $0.frame.maxX }
        let first = strip.pills.first
        // The pills sit in the middle of the 46 high strip, after the window buttons with a 10 point gap.
        let placed =
            strip.pills.allSatisfy { abs(($0.frame.y + $0.frame.height / 2) - 23) <= 1 }
            && abs((first?.frame.x ?? 0) - (strip.buttonsTrailingEdge + 10)) <= 0.5
        run.check(
            "toptabs.strip.pills",
            passed: strip.titles == Array(sidebarTabs.dropFirst()) && !strip.titles.contains("Pinned")
                && strip.pills.allSatisfy { $0.frame.width == 190 && $0.frame.height == 32 && $0.radius == 10 }
                && gaps.allSatisfy { abs($0 - 8) <= 0.5 } && placed
                && strip.pills.allSatisfy {
                    $0.titleSize == 13 && $0.titleOneLine && abs($0.iconX - 12) <= 0.5 && $0.iconSize == 15
                        && abs($0.titleX - 35) <= 0.5
                },
            "sidebar=\(sidebarTabs) gaps=\(gaps) \(strip)")

        // The window opens on the pinned tab, which has no pill; showing the first pill's tab lifts it.
        let strip0 = try await run.step("press the first pill", timeout: E2ETimeouts.step) {
            let before = try app.tabStrip(of: page)
            try app.pressTopPill(0, in: page)
            _ = try await TopTabsTests.until { try app.tabStrip(of: page).activeIndex == 0 }
            return (before, try app.tabStrip(of: page))
        }
        let lifted = strip0.1
        let top = lifted.pills.first
        let others = lifted.pills.dropFirst()
        run.check(
            "toptabs.strip.active",
            passed: strip0.0.activeIndex == nil && lifted.activeIndex == 0 && top?.fill == "#FFFFFF"
                && top?.titleBold == true && top?.shadowBlur == 3 && top?.shadowOffsetY == -1
                && abs((top?.shadowOpacity ?? 0) - 0.14) < 0.005
                && others.allSatisfy { $0.fill == nil && !$0.titleBold && $0.shadowBlur == 0 && !$0.isActive },
            "before=\(strip0.0) \(lifted)")

        if let design = run.app as? any E2EDesignApp {
            let folder = run.dataDirectory.deletingLastPathComponent().appendingPathComponent("toptabs")
            try await run.step("screenshot the strip", timeout: E2ETimeouts.step) {
                try await design.writeScreenshot(of: page, to: folder.appendingPathComponent("tab-strip.png"))
            }
        }

        // The + button follows the last pill by 8 points, in the Soft color, and opens the command bar like Cmd+T.
        let plusGap = strip.plus.x - (strip.pills.last?.frame.maxX ?? 0)
        let opened = try await run.step("click +", timeout: E2ETimeouts.step) {
            let bar = try app.commandBar(of: page)
            try app.clickTopPlus(in: page)
            let shown = try await TopTabsTests.until { bar.isShown && bar.hasKeyboard }
            let text = bar.text
            try bar.press(.escape)
            _ = try await TopTabsTests.until { !bar.isShown }
            return (shown, text)
        }
        run.check(
            "toptabs.strip.plus",
            passed: opened.0 && opened.1.isEmpty && abs(plusGap - 8) <= 0.5 && strip.plus.width == 32
                && strip.plus.height == 32 && strip.plusTint == "#7A5A48",
            "opened=\(opened.0) text=\"\(opened.1)\" gap=\(plusGap) \(strip)")

        // A click on the second pill shows its tab: the page changes and the pill lifts.
        let selected = try await run.step("press the second pill", timeout: E2ETimeouts.step) {
            try app.pressTopPill(1, in: page)
            _ = try await TopTabsTests.until {
                try app.tabStrip(of: page).activeIndex == 1
                    && app.topTabs(of: page).urlText == "bow.test/chrome/keys.html"
            }
            return (try app.tabStrip(of: page), try app.topTabs(of: page))
        }
        run.check(
            "toptabs.strip.select",
            passed: selected.0.activeIndex == 1 && selected.0.pills[1].fill == "#FFFFFF"
                && selected.0.pills[0].fill == nil && selected.1.urlText == "bow.test/chrome/keys.html",
            "\(selected.0) url=\(selected.1.urlText)")

        // The close button shows on the shown pill and on a hovered one, and closes its tab.
        let hovered = try await run.step("hover the third pill", timeout: E2ETimeouts.step) {
            let before = try app.tabStrip(of: page)
            try app.hoverTopPill(2, true, in: page)
            let during = try app.tabStrip(of: page)
            try app.hoverTopPill(2, false, in: page)
            return (before, during, try app.tabStrip(of: page))
        }
        let closed = try await run.step("close the shown pill", timeout: E2ETimeouts.step) {
            try app.clickTopPillClose(1, in: page)
            _ = try await TopTabsTests.until { try app.tabStrip(of: page).pills.count == 2 }
            return (try app.tabStrip(of: page), try app.spaces(of: page).tabs)
        }
        run.check(
            "toptabs.strip.close",
            passed: hovered.0.pills.map(\.closeShown) == [false, true, false]
                && hovered.1.pills.map(\.closeShown) == [false, true, true]
                && hovered.2.pills.map(\.closeShown) == [false, true, false]
                && closed.0.pills.count == 2 && closed.0.pills.filter(\.isActive).count == 1
                && closed.1.count == 3 && Array(closed.1.dropFirst()) == closed.0.titles,
            "hover: \(hovered.0.pills.map(\.closeShown)) \(hovered.1.pills.map(\.closeShown)) "
                + "\(hovered.2.pills.map(\.closeShown)) closed: \(closed.0) sidebar=\(closed.1)")

        // Another Space brings its own tabs, too many for the strip: the pills shrink to the minimum and scroll.
        let crowded = try await run.step("switch to the crowd Space", timeout: E2ETimeouts.step) {
            try app.clickTopSpaceDot(1, in: page)
            _ = try await TopTabsTests.until { try app.tabStrip(of: page).pills.count == 14 }
            return try app.tabStrip(of: page)
        }
        let content = 14.0 * 96 + 13 * 8
        run.check(
            "toptabs.strip.crowded",
            passed: crowded.pills.allSatisfy { $0.frame.width == 96 } && crowded.viewportWidth < content
                && abs(crowded.plus.x - (crowded.stripWidth - 14 - 32)) <= 0.5,
            "content=\(content) \(crowded)")

        // Showing a tab far along the strip scrolls its pill into view.
        let far = try await run.step("press the last pill", timeout: E2ETimeouts.step) {
            try app.pressTopPill(13, in: page)
            _ = try await TopTabsTests.until { try app.tabStrip(of: page).activeIndex == 13 }
            return try app.tabStrip(of: page)
        }
        let lastFrame = far.pills[13].frame
        let viewStart = far.buttonsTrailingEdge + 10
        run.check(
            "toptabs.strip.reveal",
            passed: far.scrollOffset > 0 && lastFrame.x >= viewStart - 0.5
                && lastFrame.maxX <= viewStart + far.viewportWidth + 0.5,
            "\(far)")

        // Closing tabs until the rest fit shrinks the pills evenly: between the minimum and the full width, together
        // filling the room the strip has.
        let fitted = try await run.step("close pills until they fit", timeout: E2ETimeouts.step) {
            var state = try app.tabStrip(of: page)
            for _ in 0..<14 {
                if let width = state.pills.first?.frame.width, width > 96.5 { break }
                let count = state.pills.count
                try app.hoverTopPill(count - 1, true, in: page)
                try app.clickTopPillClose(count - 1, in: page)
                _ = try await TopTabsTests.until { try app.tabStrip(of: page).pills.count < count }
                state = try app.tabStrip(of: page)
            }
            return state
        }
        let width = fitted.pills.first?.frame.width ?? 0
        let filled = (fitted.pills.last?.frame.maxX ?? 0) - (fitted.pills.first?.frame.x ?? 0)
        run.check(
            "toptabs.strip.shrink",
            passed: width > 96.5 && width <= 190 && fitted.pills.allSatisfy { abs($0.frame.width - width) <= 0.5 }
                && (width == 190 || abs(filled - fitted.viewportWidth) <= 1) && fitted.scrollOffset == 0,
            "width=\(width) filled=\(filled) \(fitted)")

        // Back to the first Space: its tabs are in the strip again.
        let back = try await run.step("switch back to the work Space", timeout: E2ETimeouts.step) {
            try app.clickTopSpaceDot(0, in: page)
            _ = try await TopTabsTests.until { try app.tabStrip(of: page).pills.count == 2 }
            return (try app.tabStrip(of: page), try app.spaces(of: page).tabs)
        }
        let crowdTitles = crowded.titles.filter { $0.hasPrefix("Crowd") }
        run.check(
            "toptabs.strip.spaces",
            passed: crowdTitles.count == 13 && !crowded.titles.contains("A")
                && !back.0.titles.contains { $0.hasPrefix("Crowd") } && back.1.count == 3
                && Array(back.1.dropFirst()) == back.0.titles,
            "crowd=\(crowded.titles) back=\(back.0.titles) sidebar=\(back.1)")

        _ = try await run.step("choose Use Top Tabs again", timeout: E2ETimeouts.step) {
            try app.chooseUseTopTabs(in: page)
            _ = try await TopTabsTests.until { try !app.topTabs(of: page).barShown }
        }
    }
}
