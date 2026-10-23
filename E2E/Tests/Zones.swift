import Foundation

/// Tests of the sidebar's zones: new tabs open in today, dragging a row across the divider pins and unpins its tab,
/// and the divider sits between pinned and today. Uses the sidebar fixtures in E2E/Fixtures/sidebar/.
@MainActor
enum ZonesTests {
    static let all: [any E2ETest] = [ZonesTest()]
}

/// Opens tab A, then tab B with the New Tab button, and checks B lands in today. Drags A into pinned and checks the
/// outline reads Favorites, pinned A, the divider, then today B, with B still active; then drags A back below B and
/// checks it is unpinned there. Then drops A on the divider row and checks it goes to the top of today, and drops B on
/// A's row and checks it goes above A. Every drag goes through the outline's drop routing, onto an outline row.
struct ZonesTest: E2ETest {
    let name = "zones"
    let checks = ["zones", "zones.pin", "zones.unpin", "zones.divider", "zones.drop-divider", "zones.drop-tab"]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EZonesApp else { throw E2EError("the app has no sidebar zones to drive") }
        let url = { (name: String) in E2EFixture.url("sidebar/page.html?name=\(name)") }
        /// The outline row labelled `label` in `page`'s window.
        func row(_ label: String, in page: any E2EPage) throws -> Int {
            let outline = try app.sidebarOutline(of: page)
            guard let row = outline.firstIndex(of: label) else {
                throw E2EError("no outline row \(label) in \(outline.joined(separator: " | "))")
            }
            return row
        }
        let a = try await run.step("open window", timeout: E2ETimeouts.firstLoad) {
            let page = try await run.app.openWindow(at: url("A"))
            _ = try await page.waitForLoad(after: 0)
            return page
        }
        let b = try await run.step("new tab B", timeout: E2ETimeouts.firstLoad) {
            let b = try app.clickNewTab(besides: a, opening: url("B"))
            _ = try await b.waitForLoad(after: 0)
            try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B"] }
            return b
        }
        let zoneA = try app.sidebarZone(of: a) ?? "none"
        let zoneB = try app.sidebarZone(of: b) ?? "none"
        run.check(
            name, passed: zoneA == "today" && zoneB == "today",
            zoneA == "today" ? "new_tab=\(zoneB)" : "new_tab=\(zoneB) first=\(zoneA)")

        let pinned = try await run.step("drag A into pinned", timeout: E2ETimeouts.step) {
            try app.dragTab(a, onRow: try row("pinned", in: a), childIndex: 0)
            let rows = try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B"] }
            return (zone: try app.sidebarZone(of: a) ?? "none", rows: rows, outline: try app.sidebarOutline(of: a))
        }
        let pinSummary = "A=\(pinned.zone) \(SidebarWaits.summary(pinned.rows))"
        run.check(
            "zones.pin", passed: pinned.zone == "pinned" && SidebarWaits.summary(pinned.rows) == "tabs=[A,B] active=B",
            pinSummary)
        let outline = pinned.outline.joined(separator: " | ")
        run.check(
            "zones.divider", passed: pinned.outline == ["favorites", "pinned", "A", "divider", "today", "B"], outline)

        let unpinned = try await run.step("drag A back into today", timeout: E2ETimeouts.step) {
            try app.dragTab(a, onRow: try row("today", in: a), childIndex: 1)
            let rows = try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["B", "A"] }
            return (zone: try app.sidebarZone(of: a) ?? "none", rows: rows)
        }
        let unpinSummary = "A=\(unpinned.zone) \(SidebarWaits.summary(unpinned.rows))"
        run.check(
            "zones.unpin",
            passed: unpinned.zone == "today" && SidebarWaits.summary(unpinned.rows) == "tabs=[B,A] active=B",
            unpinSummary)

        // A drop on the divider row itself lands at the top of today.
        let onDivider = try await run.step("drop A on the divider", timeout: E2ETimeouts.step) {
            try app.dragTab(a, onRow: try row("divider", in: a), childIndex: -1)
            _ = try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["A", "B"] }
            return try app.sidebarOutline(of: a)
        }
        run.check(
            "zones.drop-divider", passed: onDivider == ["favorites", "pinned", "divider", "today", "A", "B"],
            onDivider.joined(separator: " | "))

        // A drop on a tab's row lands above that tab.
        let onTab = try await run.step("drop B on tab A", timeout: E2ETimeouts.step) {
            try app.dragTab(b, onRow: try row("A", in: a), childIndex: -1)
            _ = try await SidebarWaits.rows(app, of: a) { $0.map(\.title) == ["B", "A"] }
            return try app.sidebarOutline(of: a)
        }
        run.check(
            "zones.drop-tab", passed: onTab == ["favorites", "pinned", "divider", "today", "B", "A"],
            onTab.joined(separator: " | "))
    }
}
