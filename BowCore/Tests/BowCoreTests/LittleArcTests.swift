import CoreGraphics
import Foundation
import Testing

@testable import BowCore

@Suite struct LittleArcTests {
    // MARK: Where a link opens

    @Test func linksOpenInLittleArcByDefault() {
        #expect(LittleArc.opensExternalLinksByDefault)
        #expect(LittleArc.opening(setting: nil, hasBrowserWindow: true) == .littleArc)
        #expect(LittleArc.opening(setting: true, hasBrowserWindow: true) == .littleArc)
    }

    @Test func settingOffOpensInTheBrowserWindow() {
        #expect(LittleArc.opening(setting: false, hasBrowserWindow: true) == .browserWindow)
        #expect(LittleArc.opening(setting: false, hasBrowserWindow: false) == .browserWindow)
    }

    @Test func withNoBrowserWindowTheLinkOpensAWindowAsBefore() {
        #expect(LittleArc.opening(setting: nil, hasBrowserWindow: false) == .browserWindow)
        #expect(LittleArc.opening(setting: true, hasBrowserWindow: false) == .browserWindow)
    }

    // MARK: Where a page moves

    /// Home (on screen) and Work in the default profile, Personal in profile "personal".
    private func graph() throws -> SidebarGraph {
        try SidebarGraph.sample().applying([
            .insertSpace("work", title: "Work"),
            .insertSpace("personal", title: "Personal", profileID: "personal"),
        ])
    }

    @Test func everySpaceIsListedInOrderAndOnlyTheSameProfileIsEnabled() throws {
        let targets = LittleArc.moveTargets(in: try graph(), profileID: .default)
        #expect(targets.map(\.title) == ["Home", "Work", "Personal"])
        #expect(targets.map(\.shortcutNumber) == [1, 2, 3])
        #expect(targets.map(\.isEnabled) == [true, true, false])
        #expect(targets.map(\.isOnScreen) == [true, false, false])
    }

    @Test func ctrlNumberPicksThatSpace() throws {
        let targets = LittleArc.moveTargets(in: try graph(), profileID: .default)
        #expect(LittleArc.target(shortcutNumber: 2, in: targets)?.spaceID == "work")
        #expect(LittleArc.target(shortcutNumber: 1, in: targets)?.spaceID == "home")
    }

    @Test func ctrlNumberOfAnotherProfileOrNoSpaceDoesNothing() throws {
        let targets = LittleArc.moveTargets(in: try graph(), profileID: .default)
        #expect(LittleArc.target(shortcutNumber: 3, in: targets) == nil)
        #expect(LittleArc.target(shortcutNumber: 4, in: targets) == nil)
        #expect(LittleArc.target(shortcutNumber: 0, in: targets) == nil)
    }

    @Test func openInBowMovesIntoTheSpaceOnScreen() throws {
        let targets = LittleArc.moveTargets(in: try graph(), profileID: .default)
        #expect(LittleArc.openTarget(in: targets)?.spaceID == "home")
    }

    @Test func openInBowDoesNothingWhenTheSpaceOnScreenHasAnotherProfile() throws {
        var graph = try graph()
        try graph.apply(.setActiveSpace("personal"))
        let targets = LittleArc.moveTargets(in: graph, profileID: .default)
        #expect(LittleArc.openTarget(in: targets) == nil)
        // The page of the other profile moves there instead.
        let personal = LittleArc.moveTargets(in: graph, profileID: "personal")
        #expect(LittleArc.openTarget(in: personal)?.spaceID == "personal")
        #expect(personal.map(\.isEnabled) == [false, false, true])
    }

    @Test func spacesPastTheNinthHaveNoShortcut() throws {
        var graph = SidebarGraph.sample()
        for number in 2...11 { try graph.apply(.insertSpace(SidebarSpaceID("s\(number)"), title: "S\(number)")) }
        let targets = LittleArc.moveTargets(in: graph, profileID: .default)
        #expect(targets.count == 11)
        #expect(targets[8].shortcutNumber == 9)
        #expect(targets[9].shortcutNumber == nil && targets[10].shortcutNumber == nil)
        #expect(targets[10].isEnabled)
    }

    // MARK: Where the window goes

    @Test func theWindowIsCompactAndCenteredOnALargeScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
        let frame = LittleArc.frame(in: screen)
        #expect(frame.size == LittleArc.defaultSize)
        #expect(frame.midX == screen.midX && frame.midY == screen.midY)
    }

    @Test func theWindowShrinksOnASmallScreenButNotBelowItsMinimum() {
        let small = CGRect(x: 100, y: 50, width: 800, height: 500)
        let frame = LittleArc.frame(in: small)
        #expect(frame.width == 720 && frame.height == 420)
        #expect(frame.minX == 140 && frame.minY == 90)
        let tiny = LittleArc.frame(in: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(tiny.size == LittleArc.minimumSize)
    }

    @Test func theWindowSitsOnWholePoints() {
        let frame = LittleArc.frame(in: CGRect(x: 0.5, y: 0.25, width: 1441, height: 901))
        #expect(frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded())
    }

    @Test func theWindowOpensOnTheScreenUnderThePointer() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(LittleArc.screenIndex(pointer: CGPoint(x: 2000, y: 500), screens: screens, fallback: 0) == 1)
        #expect(LittleArc.screenIndex(pointer: CGPoint(x: 10, y: 10), screens: screens, fallback: 1) == 0)
    }

    @Test func withThePointerOnNoScreenTheFallbackScreenIsUsed() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let away = CGPoint(x: -5000, y: -5000)
        #expect(LittleArc.screenIndex(pointer: away, screens: screens, fallback: 1) == 1)
        #expect(LittleArc.screenIndex(pointer: away, screens: screens, fallback: 7) == 0)
        #expect(LittleArc.screenIndex(pointer: away, screens: screens, fallback: nil) == 0)
        #expect(LittleArc.screenIndex(pointer: away, screens: [], fallback: nil) == nil)
    }
}
