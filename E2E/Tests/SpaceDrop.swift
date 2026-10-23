import Foundation

/// Dropping a sidebar tab on a Space's icon in the footer switcher moves it there, as Move to Space does.
/// Fixtures in E2E/Fixtures/profiles/.
@MainActor
enum SpaceDropTests {
    static let all: [any E2ETest] = [SpacesDropMoveTest(), SpacesDropOtherProfileTest(), SpacesDropRefuseTest()]

    static func app(of run: E2ERun) throws -> any E2ESpaceDropApp {
        guard let app = run.app as? any E2ESpaceDropApp else { throw E2EError("the app cannot drive Space drops") }
        return app
    }
}

/// Drops the fixture tab M (selected, with text typed into its field) from "Work A" on the icon of "Work B" (the
/// same profile): the icon rings while the drag is over it, the row moves with no question, and in Work B it shows
/// the same live page (the same tab, its load ID and text unchanged).
struct SpacesDropMoveTest: E2ETest {
    let name = "spaces.drop_move"

    func run(_ run: E2ERun) async throws {
        let drops = try SpaceDropTests.app(of: run)
        let setup = try await E2EProfileMoves.open(run)
        let page = setup.page
        let workB = try setup.space("Work B")
        let item = try setup.app.sidebarItemID(of: page)
        let before = try await run.step("type into the page", timeout: E2ETimeouts.step) {
            try await E2EProfileMoves.type("dropped words", into: page)
            return try await E2EProfileMoves.state(of: page)
        }
        let after = try await run.step("drop it on Work B's icon and show it there", timeout: E2ETimeouts.firstLoad) {
            let drag = try drops.dragOnSpaceIcon(item: item, space: "Work B", end: .drop, in: page)
            let asked = try setup.app.sheetMessage(in: page)
            let space = try await E2EWaits.value({ try setup.spaceOf(page) }, until: { $0 == workB })
            try setup.app.switchToSpace(workB, besides: page)
            let shown = try await E2EWaits.value(
                { try setup.app.shownPage(besides: page) }, until: { $0 != nil && $0?.isClosed == false })
            let same = shown.map { ($0 as AnyObject) === (page as AnyObject) } ?? false
            return (
                drag: drag, asked: asked, space: space, same: same, closed: page.isClosed,
                state: try await E2EProfileMoves.state(of: page)
            )
        }
        let passed =
            after.drag
            == E2ESpaceDropResult(operation: "move", ringedOver: true, ringedAfter: false, performed: true)
            && after.asked == nil && after.space == workB && after.same && !after.closed && after.state == before
            && before.hasPrefix("dropped words|")
        run.check(
            name, passed: passed,
            "drag=[\(after.drag)] asked=\(after.asked ?? "none") moved=\(after.space == workB) "
                + "same_tab=\(after.same) closed=\(after.closed) page_kept=\(after.state == before)")
    }
}

/// Drops the fixture tab M on the icon of "Home" (another profile): a sheet asks first, Cancel leaves the tab in
/// "Work A" with its live page and text, and nothing is closed.
struct SpacesDropOtherProfileTest: E2ETest {
    let name = "spaces.drop_other_profile"

    func run(_ run: E2ERun) async throws {
        let drops = try SpaceDropTests.app(of: run)
        let setup = try await E2EProfileMoves.open(run)
        let page = setup.page
        let workA = try setup.space("Work A")
        let item = try setup.app.sidebarItemID(of: page)
        let before = try await run.step("type into the page", timeout: E2ETimeouts.step) {
            try await E2EProfileMoves.type("not leaving", into: page)
            return try await E2EProfileMoves.state(of: page)
        }
        let asked = try await run.step("drop it on Home's icon, which asks", timeout: E2ETimeouts.step) {
            let drag = try drops.dragOnSpaceIcon(item: item, space: "Home", end: .drop, in: page)
            let message = try await E2EWaits.value({ try setup.app.sheetMessage(in: page) }, until: { $0 != nil })
            return (drag: drag, message: message)
        }
        let cancelled = try await run.step("answer Cancel", timeout: E2ETimeouts.step) {
            try setup.app.answerSheet("Cancel", text: nil, in: page)
            _ = try await E2EWaits.value({ try setup.app.sheetMessage(in: page) }, until: { $0 == nil })
            return (space: try setup.spaceOf(page), closed: page.isClosed)
        }
        let after = try await E2EProfileMoves.state(of: page)
        let passed =
            asked.drag.operation == "move" && asked.drag.performed && asked.message?.contains("Home") == true
            && cancelled.space == workA && !cancelled.closed && after == before
        run.check(
            name, passed: passed,
            "drag=[\(asked.drag)] asked=\(asked.message?.contains("Home") == true) stayed=\(cancelled.space == workA) "
                + "closed=\(cancelled.closed) page_kept=\(after == before)")
    }
}

/// Refusals: a folder and a Favorite dropped on another Space's icon, and a tab dropped on the icon of the Space it
/// is already in, change nothing and show no ring; a drag that leaves an icon without a drop moves nothing and
/// clears the ring.
struct SpacesDropRefuseTest: E2ETest {
    let name = "spaces.drop_refuse"
    let checks = ["spaces.drop_refuse", "spaces.drop_leave"]

    func run(_ run: E2ERun) async throws {
        let drops = try SpaceDropTests.app(of: run)
        guard let seeder = run.app as? any E2EStoreSeedApp else { throw E2EError("the app lacks the store seed hooks") }
        let seed = E2ESeed(spaces: [
            E2ESeedSpace(
                "Work A",
                today: [
                    .tab("M", url: E2EProfileMoves.moveURL),
                    .tab("Fav", url: E2EFixture.url("profiles/index.html?space=fav")),
                    .folder("Box", [.tab("Inner", url: E2EFixture.url("profiles/index.html?space=inner"))]),
                ]),
            E2ESeedSpace("Work B", today: [.tab("B1", url: E2EFixture.url("profiles/index.html?space=wb"))]),
        ])
        let window = try await run.step("open the seeded window", timeout: E2ETimeouts.firstLoad) {
            let window = try await seeder.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window
        }
        let page = window.page
        guard let m = window.itemIDs["M"], let fav = window.itemIDs["Fav"], let box = window.itemIDs["Box"] else {
            throw E2EError("the seed has no M, Fav or Box")
        }
        let refused = try await run.step("drop a folder, a Favorite and M on icons", timeout: E2ETimeouts.step) {
            guard try drops.dropOnFavoritesGrid(item: fav, in: page) else {
                throw E2EError("Fav did not become a Favorite")
            }
            let entries = { try [m, fav, box].map { try seeder.storeEntry(id: $0, in: page)?.description ?? "none" } }
            let before = try entries()
            let folder = try drops.dragOnSpaceIcon(item: box, space: "Work B", end: .drop, in: page)
            let favorite = try drops.dragOnSpaceIcon(item: fav, space: "Work B", end: .drop, in: page)
            let own = try drops.dragOnSpaceIcon(item: m, space: "Work A", end: .drop, in: page)
            return (folder: folder, favorite: favorite, own: own, unchanged: try entries() == before)
        }
        let none = E2ESpaceDropResult(operation: "none", ringedOver: false, ringedAfter: false, performed: false)
        // The Space already on screen keeps its own resting ring, so only its answer and result are compared.
        let ownRefused = refused.own.operation == "none" && !refused.own.performed
        run.check(
            name,
            passed: refused.folder == none && refused.favorite == none && ownRefused && refused.unchanged,
            "folder=[\(refused.folder)] favorite=[\(refused.favorite)] own=[\(refused.own)] "
                + "unchanged=\(refused.unchanged)")

        let left = try await run.step("leave Work B's icon with M, no drop", timeout: E2ETimeouts.step) {
            let drag = try drops.dragOnSpaceIcon(item: m, space: "Work B", end: .leave, in: page)
            let entry = try seeder.storeEntry(id: m, in: page)
            return (drag: drag, space: entry?.spaceID, sheet: try drops.sheetMessage(in: page))
        }
        let workA = window.spaceIDs["Work A"]
        run.check(
            "spaces.drop_leave",
            passed: left.drag
                == E2ESpaceDropResult(operation: "move", ringedOver: true, ringedAfter: false, performed: false)
                && left.space == workA && left.sheet == nil,
            "drag=[\(left.drag)] stayed=\(left.space == workA) asked=\(left.sheet ?? "none")")
    }
}
