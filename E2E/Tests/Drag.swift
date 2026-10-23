import Foundation

/// Dragging sidebar rows by pointer position: the drag starts at a row's middle and is let go at a point, and the
/// outline works out from that point where the row goes, as it does under a person's pointer. Reuses the sidebar
/// fixtures.
@MainActor
enum DragTests {
    static let all: [any E2ETest] = [DragPointerTest()]
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
