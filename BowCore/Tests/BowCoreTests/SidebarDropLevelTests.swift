import Testing

@testable import BowCore

@Suite struct SidebarDropLevelTests {
    // MARK: Levels a gap offers

    @Test func belowAFoldersLastChildOffersTheFolderAndItsParent() {
        // Folder at level 1 with its last child at level 2, then a tab at level 1.
        #expect(SidebarDropLevel.levels(above: 2, aboveOpensChildren: false, below: 1) == 1...2)
    }

    @Test func twoLevelsDeepAtTheEndOfTheListOffersEveryLevel() {
        #expect(SidebarDropLevel.levels(above: 3, aboveOpensChildren: false, below: nil) == 1...3)
    }

    @Test func belowAnOpenFolderWithChildrenOffersOnlyItsFirstSlot() {
        #expect(SidebarDropLevel.levels(above: 1, aboveOpensChildren: true, below: 2) == 2...2)
    }

    @Test func belowAnOpenEmptyFolderOffersInsideOrBeside() {
        #expect(SidebarDropLevel.levels(above: 1, aboveOpensChildren: true, below: 1) == 1...2)
    }

    @Test func belowAClosedFolderOffersOnlyBesideIt() {
        #expect(SidebarDropLevel.levels(above: 1, aboveOpensChildren: false, below: 1) == 1...1)
    }

    @Test func belowASectionHeaderOffersItsFirstSlot() {
        #expect(SidebarDropLevel.levels(above: 0, aboveOpensChildren: true, below: 1) == 1...1)
        #expect(SidebarDropLevel.levels(above: 0, aboveOpensChildren: true, below: 0) == 1...1)
    }

    @Test func aboveTheNextSectionNeverOffersTheSectionLevel() {
        #expect(SidebarDropLevel.levels(above: 2, aboveOpensChildren: false, below: 0) == 1...2)
    }

    // MARK: The pointer's level

    /// Level 1 rows start at x 20, and each level steps in 22 points, as the sidebar's folder rows do.
    private func level(_ x: Double, _ levels: ClosedRange<Int>) -> Int {
        SidebarDropLevel.level(pointerX: x, firstLevelX: 20, step: 22, in: levels)
    }

    @Test func atTheFoldersOwnXTheDropLeavesTheFolder() {
        // The folder's row starts at 20 and its children's at 42.
        #expect(level(20, 1...2) == 1)
        #expect(level(28, 1...2) == 1)
        #expect(level(41, 1...2) == 1)
    }

    @Test func atTheChildrensXTheDropStaysInTheFolder() {
        #expect(level(42, 1...2) == 2)
        #expect(level(60, 1...2) == 2)
    }

    @Test func twoLevelsDeepEachStepIsTwentyTwoPoints() {
        #expect(level(30, 1...3) == 1)
        #expect(level(50, 1...3) == 2)
        #expect(level(70, 1...3) == 3)
    }

    @Test func thePointerStaysWithinTheGapsLevels() {
        #expect(level(-1000, 2...3) == 2)
        #expect(level(0, 2...3) == 2)
        #expect(level(1000, 1...2) == 2)
        #expect(level(.greatestFiniteMagnitude, 1...2) == 2)
        #expect(level(-.greatestFiniteMagnitude, 1...2) == 1)
    }

    @Test func aSingleLevelGapIgnoresThePointer() {
        #expect(level(0, 2...2) == 2)
        #expect(level(500, 1...1) == 1)
    }

    @Test func noStepOrNoPointerKeepsTheDeepestLevel() {
        #expect(SidebarDropLevel.level(pointerX: .nan, firstLevelX: 20, step: 22, in: 1...3) == 3)
        #expect(SidebarDropLevel.level(pointerX: 30, firstLevelX: 20, step: 0, in: 1...3) == 3)
    }
}
