import Foundation
import Testing

@testable import BowCore

@Suite struct SpacePaletteTests {
    private static let themes = [SpaceTheme.default] + SpaceTint.presets.map(\.theme)
    private let blue = try! SpaceTheme(primaryColorHex: "#3B5BDB")

    private func roles(_ palette: SpacePalette) -> [(String, SpaceTintColor)] {
        [
            ("background", palette.background), ("backgroundExtra", palette.backgroundExtra),
            ("title", palette.title), ("subtitle", palette.subtitle),
            ("foregroundPrimary", palette.foregroundPrimary), ("foregroundSecondary", palette.foregroundSecondary),
            ("foregroundTertiary", palette.foregroundTertiary), ("hover", palette.hover),
            ("selectedFill", palette.selectedFill), ("tileFill", palette.tileFill), ("fieldFill", palette.fieldFill),
            ("divider", palette.divider), ("focus", palette.focus),
        ]
    }

    @Test func theDefaultThemeIsTheBrandKit() {
        let light = SpacePalette(theme: .default, appearance: .light)
        let dark = SpacePalette(theme: .default, appearance: .dark)
        #expect(light.background.hex == "#FFF3E6")
        #expect(dark.background.hex == "#2A1710")
        #expect(light.title.hex == "#3A1F14")
        #expect(dark.title.hex == "#FFF3E6")
        #expect(light.backdropOpacity == 0)
        #expect(dark.backdropOpacity == 0)
    }

    @Test func aDefaultColorThemeIsTheDefaultTheme() throws {
        let same = try SpaceTheme(primaryColorHex: "8e96a8")
        #expect(SpacePalette(theme: same, appearance: .light) == SpacePalette(theme: .default, appearance: .light))
    }

    @Test(arguments: SpacePaletteAppearance.allCases)
    func textIsReadableOnEveryPreset(appearance: SpacePaletteAppearance) {
        for theme in Self.themes {
            let palette = SpacePalette(theme: theme, appearance: appearance)
            let name = "\(theme.primaryColor.hex) \(appearance)"
            #expect(palette.foregroundPrimary.contrast(with: palette.background) >= 7, "primary \(name)")
            #expect(palette.title.contrast(with: palette.background) >= 7, "title \(name)")
            #expect(palette.foregroundSecondary.contrast(with: palette.background) >= 4.5, "secondary \(name)")
            #expect(palette.subtitle.contrast(with: palette.background) >= 4.5, "subtitle \(name)")
            #expect(palette.focus.contrast(with: palette.background) >= 3, "focus \(name)")
        }
    }

    @Test(arguments: SpacePaletteAppearance.allCases)
    func theTextRolesStepDownInStrength(appearance: SpacePaletteAppearance) {
        for theme in Self.themes {
            let palette = SpacePalette(theme: theme, appearance: appearance)
            let primary = palette.foregroundPrimary.contrast(with: palette.background)
            let secondary = palette.foregroundSecondary.contrast(with: palette.background)
            let tertiary = palette.foregroundTertiary.contrast(with: palette.background)
            #expect(primary > secondary && secondary > tertiary && tertiary > 1.5)
        }
    }

    @Test(arguments: SpacePaletteAppearance.allCases)
    func neutralsKeepTheThemesHue(appearance: SpacePaletteAppearance) {
        let neutrals = Set([
            "background", "backgroundExtra", "title", "subtitle", "foregroundPrimary", "foregroundSecondary",
            "foregroundTertiary", "hover", "selectedFill", "tileFill", "fieldFill", "divider",
        ])
        for theme in SpaceTint.presets.map(\.theme) {
            let hue = SpaceTintColor(theme.primaryColor).hsl.hue
            let palette = SpacePalette(theme: theme, appearance: appearance)
            for (role, color) in roles(palette) where neutrals.contains(role) {
                let own = color.hsl
                var gap = abs(own.hue - hue)
                gap = min(gap, 360 - gap)
                #expect(own.saturation > 0.03, "\(role) of \(theme.primaryColor.hex) lost its tint")
                #expect(gap <= 8, "\(role) of \(theme.primaryColor.hex) \(appearance) has hue \(own.hue), not \(hue)")
            }
        }
    }

    @Test func everyRoleDiffersFromTheCreamOfTheDefaultInEverySpace() {
        let cream = SpacePalette(theme: .default, appearance: .light)
        for theme in SpaceTint.presets.map(\.theme) {
            let palette = SpacePalette(theme: theme, appearance: .light)
            for ((role, color), (_, creamColor)) in zip(roles(palette), roles(cream)) {
                #expect(color != creamColor, "\(role) of \(theme.primaryColor.hex) stayed cream")
            }
        }
    }

    @Test func surfacesStepAwayFromTheBackground() {
        for theme in Self.themes {
            for appearance in SpacePaletteAppearance.allCases {
                let palette = SpacePalette(theme: theme, appearance: appearance)
                let surfaces = [
                    palette.hover, palette.selectedFill, palette.tileFill, palette.fieldFill, palette.divider,
                ]
                #expect(Set(surfaces + [palette.background]).count == 6)
                #expect(palette.backgroundExtra != palette.background)
            }
        }
    }

    @Test func backdropOpacityIsAFractionAndOnlyThemedSpacesHaveOne() {
        for theme in Self.themes {
            for appearance in SpacePaletteAppearance.allCases {
                let opacity = SpacePalette(theme: theme, appearance: appearance).backdropOpacity
                #expect((0...1).contains(opacity))
                #expect((opacity > 0) == (theme != .default))
            }
        }
    }

    @Test func aPaletteIsPure() {
        #expect(
            SpacePalette(theme: blue, appearance: .dark) == SpacePalette(theme: blue, appearance: .dark))
        #expect(
            SpacePalette(theme: blue, appearance: .dark) != SpacePalette(theme: blue, appearance: .light))
    }

    @Test func bluesLightValuesArePinned() {
        let p = SpacePalette(theme: blue, appearance: .light)
        #expect(
            roles(p).map { "\($0.0)=\($0.1.hex)" }.joined(separator: " ")
                == "background=#DDE2F9 backgroundExtra=#D2D7EC title=#121935 subtitle=#4B526C "
                + "foregroundPrimary=#121935 foregroundSecondary=#4B526C foregroundTertiary=#777E97 hover=#CED4EB "
                + "selectedFill=#F1F3FC tileFill=#EAEEFB fieldFill=#F5F6FD divider=#C4CAE1 focus=#1E39A4")
        #expect(p.backdropOpacity == 0.5)
    }

    @Test func bluesDarkValuesArePinned() {
        let p = SpacePalette(theme: blue, appearance: .dark)
        #expect(
            roles(p).map { "\($0.0)=\($0.1.hex)" }.joined(separator: " ")
                == "background=#13192F backgroundExtra=#1F2439 title=#ECEFF8 subtitle=#AFB3C0 "
                + "foregroundPrimary=#ECEFF8 foregroundSecondary=#AFB3C0 foregroundTertiary=#808494 hover=#23283D "
                + "selectedFill=#303548 tileFill=#24293D fieldFill=#2B3044 divider=#2D3347 focus=#6881E3")
        #expect(p.backdropOpacity == 0.4)
    }

    @Test func hslRoundTripsAndContrastIsWcag() {
        let color = SpaceTintColor(try! SpaceColor(hex: "#3B5BDB"))
        let (h, s, l) = color.hsl
        #expect(SpaceTintColor(hue: h, saturation: s, lightness: l).hex == "#3B5BDB")
        let white = SpaceTintColor(red: 1, green: 1, blue: 1)
        let black = SpaceTintColor(red: 0, green: 0, blue: 0)
        #expect(abs(white.contrast(with: black) - 21) < 0.0001)
        #expect(white.contrast(with: white) == 1)
        #expect(SpaceTintColor(hue: -120, saturation: 1, lightness: 0.5).hex == "#0000FF")
        #expect(SpaceTintColor(hue: .nan, saturation: 2, lightness: 0.5).hex == "#FF0000")
    }
}
