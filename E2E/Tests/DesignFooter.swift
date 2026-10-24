import Foundation

/// The sidebar footer: the downloads and archive buttons on the left, the Space dots centred between them and the
/// "+", the active dot 14 points with an Apricot ring, each dot in its Space's theme color (the default theme keeps
/// Jam on screen and Soft otherwise), and the dot's menu offering the Space's theme and icon besides Rename and
/// Delete.
@MainActor
enum DesignFooterTests {
    static let all: [any E2ETest] = [DesignFooterTest()]
}

struct DesignFooterTest: E2ETest {
    let name = "design.footer"
    let checks = ["design.space_dot", "design.footer_centred", "design.footer_dot_colors", "design.footer_dot_menu"]

    func run(_ run: E2ERun) async throws {
        let design = try DesignTests.design(run)
        guard let app = run.app as? any E2ESpaceThemeApp & E2EStoreSeedApp else {
            throw E2EError("the app cannot drive Space themes")
        }
        // Spaces without icons, so each shows its dot.
        let page = try await run.step("open three Spaces", timeout: E2ETimeouts.firstLoad) {
            let seed = E2ESeed(spaces: [
                E2ESeedSpace("Home", today: [.tab("Reading", url: DesignTests.url("Reading"))]),
                E2ESeedSpace("Work"), E2ESeedSpace("Play"),
            ])
            let window = try await app.openWindow(seeded: seed)
            _ = try await window.page.waitForLoad(after: 0)
            return window.page
        }
        let soft = "#7A5A48"
        let plain = try await run.step("read the footer", timeout: E2ETimeouts.step) {
            _ = try await E2EWaits.until { try design.look(of: page).footer.dotColors.count == 3 }
            return try design.look(of: page).footer
        }
        run.check(
            "design.space_dot",
            passed: plain.spaceDotSize == 14 && plain.spaceRingWidth == 2 && plain.spaceRingGap == 2
                && plain.spaceRingColor == DesignTests.apricot,
            "dot=\(plain.spaceDotSize) ring=\(plain.spaceRingWidth) gap=\(plain.spaceRingGap)"
                + " ring_color=\(plain.spaceRingColor ?? "none")")
        run.check(
            "design.footer_centred",
            passed: abs(plain.dotsOffset) < 1 && plain.order,
            "offset=\(plain.dotsOffset) order=\(plain.order)")
        let themed = try await run.step("theme the Space Blue", timeout: E2ETimeouts.step) {
            try app.chooseSpaceMenuItem(["Theme", "Blue"], in: page)
            _ = try await E2EWaits.until { try design.look(of: page).footer.dotColors.first == DesignTests.blue }
            return try design.look(of: page).footer
        }
        run.check(
            "design.footer_dot_colors",
            passed: plain.dotColors == [DesignTests.jam, soft, soft]
                && themed.dotColors == [DesignTests.blue, soft, soft] && themed.spaceRingColor == DesignTests.apricot,
            "default=\(plain.dotColors) themed=\(themed.dotColors) ring=\(themed.spaceRingColor ?? "none")")
        let expected = [
            "Rename Space…", "Delete Space…", "-", "Theme", "Theme/Default", "Theme/Blue", "Theme/Jam",
            "Theme/Apricot", "Theme/Cocoa", "Theme/Green", "Theme/Brick", "Change Icon…", "Remove Icon",
        ]
        run.check(
            "design.footer_dot_menu", passed: themed.dotMenu == expected,
            "menu=\(themed.dotMenu)")
    }
}
