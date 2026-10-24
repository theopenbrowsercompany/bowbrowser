import Foundation

/// The command bar: a panel whose content is clipped to 14 point corners with a shadow path the size of the panel,
/// and its field and result rows in Nunito Sans at their own sizes.
@MainActor
enum DesignCommandBarTests {
    static let all: [any E2ETest] = [DesignCommandBarTest()]
}

struct DesignCommandBarTest: E2ETest {
    let name = "design.command_bar"
    let checks = ["design.command_bar", "design.fonts_command_bar"]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let fonts = run.app as? any E2EFontsApp else { throw E2EError("the app has no font hooks") }
        let page = try await DesignTests.openBrowsing(run)
        let read = try await run.step("open the command bar", timeout: E2ETimeouts.step) {
            let bar = try await DesignTests.openCommandBar(run, over: page)
            let look = try design.look(of: page).commandBar
            try bar.type("Plan")
            _ = try await bar.waitForResults()
            let typed = try fonts.fonts(of: page)
            try bar.press(.escape)
            _ = try await E2EWaits.until { !bar.isShown }
            return (look, typed)
        }
        let bar = read.0
        run.check(
            "design.command_bar", passed: bar.radius == 14 && bar.clips && bar.shadowHasPath,
            "radius=\(bar.radius) clips=\(bar.clips) shadow_path=\(bar.shadowHasPath)")
        let font = read.1
        let nunito = "Nunito Sans"
        run.check(
            "design.fonts_command_bar",
            passed: font.commandBarField?.family == nunito && font.commandBarField?.size == 20
                && font.commandBarRowTitle?.family == nunito && font.commandBarRowTitle?.size == 14
                && font.commandBarRowDetail?.family == nunito && font.commandBarRowDetail?.size == 12,
            "field=\(String(describing: font.commandBarField)) row_title=\(String(describing: font.commandBarRowTitle))"
                + " row_detail=\(String(describing: font.commandBarRowDetail))")
    }
}
