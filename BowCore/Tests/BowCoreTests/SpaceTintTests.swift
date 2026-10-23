import Foundation
import Testing

@testable import BowCore

@Suite struct SpaceTintTests {
    private let lightFrame = SpaceTintColor(try! SpaceColor(hex: "#FFF3E6"))
    private let darkFrame = SpaceTintColor(try! SpaceColor(hex: "#2A1710"))
    private let blue = try! SpaceTheme(primaryColorHex: "#3B5BDB")

    @Test func theDefaultThemeGivesExactlyTheFrameColor() {
        #expect(SpaceTint.color(for: .default, over: lightFrame) == lightFrame)
        #expect(SpaceTint.color(for: .default, over: darkFrame) == darkFrame)
    }

    @Test func aThemeTintsTwelvePercentInLightAndDark() {
        #expect(SpaceTint.color(for: blue, over: lightFrame).hex == "#E7E1E5")
        #expect(SpaceTint.color(for: blue, over: darkFrame).hex == "#2C1F28")
    }

    @Test func aThemeSetToTheDefaultColorTintsAsTheDefault() throws {
        let same = try SpaceTheme(primaryColorHex: "8e96a8")
        #expect(SpaceTint.color(for: same, over: lightFrame) == lightFrame)
    }

    @Test func aThemeTheColorOfTheFrameLeavesItUnchanged() throws {
        let frame = try SpaceTheme(primaryColorHex: "#FFF3E6")
        #expect(SpaceTint.color(for: frame, over: lightFrame).hex == "#FFF3E6")
    }

    @Test func blackAndWhiteThemesStayInRange() throws {
        let black = try SpaceTheme(primaryColorHex: "#000")
        let white = try SpaceTheme(primaryColorHex: "#FFF")
        #expect(SpaceTint.color(for: black, over: SpaceTintColor(red: 1, green: 1, blue: 1)).hex == "#E0E0E0")
        #expect(SpaceTint.color(for: white, over: SpaceTintColor(red: 0, green: 0, blue: 0)).hex == "#1F1F1F")
    }

    @Test func differentThemesGiveDifferentTints() {
        let tints = Set(SpaceTint.presets.map { SpaceTint.color(for: $0.theme, over: lightFrame) })
        #expect(tints.count == SpaceTint.presets.count)
        #expect(!tints.contains(lightFrame))
    }

    @Test func mixingClampsItsFraction() {
        let white = SpaceTintColor(red: 1, green: 1, blue: 1)
        let black = SpaceTintColor(red: 0, green: 0, blue: 0)
        #expect(white.mixed(with: black, fraction: -1) == white)
        #expect(white.mixed(with: black, fraction: 2) == black)
        #expect(white.mixed(with: black, fraction: .nan) == white)
        #expect(white.mixed(with: black, fraction: 0.5).hex == "#808080")
    }

    @Test func channelsOutOfRangeAreClamped() {
        let color = SpaceTintColor(red: 2, green: -1, blue: .nan)
        #expect(color.hex == "#FF0000")
    }

    @Test func presetsAreTheBrandPaletteAndABlue() {
        #expect(SpaceTint.presets.map(\.name) == ["Blue", "Jam", "Apricot", "Cocoa", "Green", "Brick"])
        #expect(
            SpaceTint.presets.map(\.theme.primaryColor.hex) == [
                "#3B5BDB", "#E8743B", "#FFC08A", "#7A5A48", "#2F7D4F", "#B84E1B",
            ])
        #expect(!SpaceTint.presets.map(\.theme).contains(.default))
    }
}
