import Foundation

/// Dragging sidebar rows by pointer position: the drag starts at a row's middle and is let go at a point, and the
/// outline works out from that point where the row goes, as it does under a person's pointer. Reuses the sidebar
/// fixtures.
@MainActor
enum DragTests {
    static let all: [any E2ETest] = [DragPointerTest(), DragPointerHalvesTest()]
}

/// Seeds pinned tabs P1 and P2, and today folder F (holding X) and tabs A, B and C. A drop on the upper half of a tab
/// row lands above it and on the lower half below it, also on the last pinned row and the last today row (a closed
/// folder F sits above the tabs). A drop on a folder row itself stays covered by the folders area.
struct DragPointerHalvesTest: E2ETest {
    let name = "drag.halves"
    let checks = [
        "drag.halves_upper", "drag.halves_lower", "drag.halves_last_today", "drag.halves_last_pinned",
        "drag.halves_across",
    ]

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EPointerDragApp & E2EStoreSeedApp else {
            throw E2EError("the app cannot drag sidebar rows by pointer")
        }
        let url = DragPointerTest.url
        let seed = E2ESeed(spaces: [
            E2ESeedSpace(
                "work", pinned: [.tab("P1", url: url("P1")), .tab("P2", url: url("P2"))],
                today: [
                    .folder("F", expanded: false, [.tab("X", url: url("X"))]), .tab("A", url: url("A")),
                    .tab("B", url: url("B")),
                    .tab("C", url: url("C")),
                ])
        ])
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        func outline(pinned: [String], today: [String]) -> [String] {
            ["favorites", "pinned"] + pinned + ["divider", "today"] + today
        }
        /// Drags `title` to `fraction` down row `target` and waits for the outline `expected`; nil when it got there.
        func drag(_ title: String, _ target: String, _ fraction: Double, expecting expected: [String]) async throws
            -> String?
        {
            let drop = try app.pointerDragSidebarRow(title, to: .row(target, fraction: fraction), in: page)
            let shown = try await E2EWaits.value({ try app.sidebarOutline(of: page) }, until: { $0 == expected })
            return drop.accepted && shown == expected ? nil : "\(drop) [\(shown.joined(separator: ","))]"
        }
        let pinned = ["P1", "P2"]
        _ = try await run.step("the sidebar lists the seeded rows", timeout: E2ETimeouts.step) {
            try await E2EWaits.value(
                { try app.sidebarOutline(of: page) },
                until: { $0 == outline(pinned: pinned, today: ["F", "A", "B", "C"]) })
        }

        let upper = try await run.step("drag C to the upper half of A", timeout: E2ETimeouts.step) {
            try await drag("C", "A", 0.25, expecting: outline(pinned: pinned, today: ["F", "C", "A", "B"]))
        }
        run.check("drag.halves_upper", passed: upper == nil, upper ?? "")

        let lower = try await run.step("drag C to the lower half of A", timeout: E2ETimeouts.step) {
            try await drag("C", "A", 0.75, expecting: outline(pinned: pinned, today: ["F", "A", "C", "B"]))
        }
        run.check("drag.halves_lower", passed: lower == nil, lower ?? "")

        let lastToday = try await run.step("drag rows around the last today row", timeout: E2ETimeouts.step) {
            let below = try await drag(
                "A", "B", 0.75, expecting: outline(pinned: pinned, today: ["F", "C", "B", "A"]))
            let above = try await drag(
                "C", "A", 0.25, expecting: outline(pinned: pinned, today: ["F", "B", "C", "A"]))
            let end = try await drag(
                "B", "A", 0.75, expecting: outline(pinned: pinned, today: ["F", "C", "A", "B"]))
            return [below, above, end].compactMap { $0 }
        }
        run.check("drag.halves_last_today", passed: lastToday.isEmpty, lastToday.joined(separator: "; "))

        let lastPinned = try await run.step("drag rows around the last pinned row", timeout: E2ETimeouts.step) {
            let today = ["F", "C", "A", "B"]
            let below = try await drag("P1", "P2", 0.75, expecting: outline(pinned: ["P2", "P1"], today: today))
            let end = try await drag("P2", "P1", 0.75, expecting: outline(pinned: ["P1", "P2"], today: today))
            let above = try await drag("P2", "P1", 0.25, expecting: outline(pinned: ["P2", "P1"], today: today))
            return [below, end, above].compactMap { $0 }
        }
        run.check("drag.halves_last_pinned", passed: lastPinned.isEmpty, lastPinned.joined(separator: "; "))

        // From the other zone: a today tab let go low on the last pinned row ends up pinned after it, and a pinned
        // tab let go low on the last today row ends up unpinned after it.
        let across = try await run.step("drag tabs across the divider onto the last rows", timeout: E2ETimeouts.step) {
            let toPinned = try await drag(
                "B", "P1", 0.9, expecting: outline(pinned: ["P2", "P1", "B"], today: ["F", "C", "A"]))
            let toToday = try await drag(
                "P2", "A", 0.9, expecting: outline(pinned: ["P1", "B"], today: ["F", "C", "A", "P2"]))
            return [toPinned, toToday].compactMap { $0 }
        }
        run.check("drag.halves_across", passed: across.isEmpty, across.joined(separator: "; "))
    }
}

/// Seeds pinned tab P and today tabs A, B and C. Letting C go near the top of A puts it above A; letting it go near
/// the bottom of B puts it below B; letting A go near the top of P moves it to the pinned tabs above P. Letting B
/// go over the page beside the sidebar drops nothing and moves nothing.
struct DragPointerTest: E2ETest {
    let name = "drag.pointer"
    let tags = ["smoke"]
    let checks = ["drag.pointer_reorder", "drag.pointer_pinned", "drag.pointer_outside"]

    static func url(_ name: String) -> URL { E2EFixture.url("sidebar/page.html?name=\(name)") }

    func run(_ run: E2ERun) async throws {
        guard let app = run.app as? any E2EPointerDragApp & E2EStoreSeedApp else {
            throw E2EError("the app cannot drag sidebar rows by pointer")
        }
        let seed = E2ESeed(spaces: [
            E2ESeedSpace(
                "work", pinned: [.tab("P", url: Self.url("P"))],
                today: [.tab("A", url: Self.url("A")), .tab("B", url: Self.url("B")), .tab("C", url: Self.url("C"))])
        ])
        let page = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        func outline(_ expected: [String]) async throws -> [String] {
            try await E2EWaits.value({ try app.sidebarOutline(of: page) }, until: { $0 == expected })
        }
        let start = ["favorites", "pinned", "P", "divider", "today", "A", "B", "C"]
        _ = try await run.step("the sidebar lists the seeded tabs", timeout: E2ETimeouts.step) {
            try await outline(start)
        }

        let reorder = try await run.step("drag C above A, then below B", timeout: E2ETimeouts.step) {
            let up = try app.pointerDragSidebarRow("C", to: .row("A", fraction: 0.1), in: page)
            let first = try await outline(["favorites", "pinned", "P", "divider", "today", "C", "A", "B"])
            let down = try app.pointerDragSidebarRow("C", to: .row("B", fraction: 0.9), in: page)
            let second = try await outline(start)
            return (up, first, down, second)
        }
        run.check(
            "drag.pointer_reorder",
            passed: reorder.0.accepted && reorder.1.suffix(3) == ["C", "A", "B"] && reorder.2.accepted
                && reorder.3 == start,
            "above A: \(reorder.0) [\(reorder.1.joined(separator: ","))] "
                + "below B: \(reorder.2) [\(reorder.3.joined(separator: ","))]")

        let pinnedOutline = ["favorites", "pinned", "A", "P", "divider", "today", "B", "C"]
        let pinned = try await run.step("drag A above P", timeout: E2ETimeouts.step) {
            let drop = try app.pointerDragSidebarRow("A", to: .row("P", fraction: 0.1), in: page)
            return (drop, try await outline(pinnedOutline))
        }
        run.check(
            "drag.pointer_pinned", passed: pinned.0.accepted && pinned.1 == pinnedOutline,
            "\(pinned.0) [\(pinned.1.joined(separator: ","))]")

        let outside = try await run.step("let B go over the page", timeout: E2ETimeouts.step) {
            let drop = try app.pointerDragSidebarRow("B", to: .page, in: page)
            return (drop, try app.sidebarOutline(of: page))
        }
        run.check(
            "drag.pointer_outside",
            passed: outside.0.destination == nil && !outside.0.accepted && outside.1 == pinnedOutline,
            "\(outside.0) [\(outside.1.joined(separator: ","))]")
    }
}
