import BowCore
import Testing

@Suite struct PageFullscreenTests {
    @Test func enteringHidesTheChromeAndEntersWindowFullScreen() {
        var state = PageFullscreen()
        #expect(
            state.pageEntered(1, isShown: true, windowIsFullScreen: false) == [.hideChrome, .toggleWindowFullScreen])
        #expect(state.tab == 1)
        #expect(state.isActive)
        #expect(state.enteredWindowFullScreen)
    }

    @Test func exitingRestoresTheChromeAndLeavesWindowFullScreen() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        #expect(state.pageExited(1) == [.showChrome, .toggleWindowFullScreen])
        #expect(!state.isActive)
        #expect(!state.enteredWindowFullScreen)
        // The page's own exit event after the window already restored changes nothing.
        #expect(state.pageExited(1) == [])
    }

    @Test func aWindowAlreadyInFullScreenStaysThere() {
        var state = PageFullscreen()
        #expect(state.pageEntered(1, isShown: true, windowIsFullScreen: true) == [.hideChrome])
        #expect(!state.enteredWindowFullScreen)
        #expect(state.pageExited(1) == [.showChrome])
    }

    @Test func aSecondRequestFromTheSamePageChangesNothing() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        // The window is in full screen by now, which must not make the exit forget to toggle back.
        #expect(state.pageEntered(1, isShown: true, windowIsFullScreen: true) == [])
        #expect(state.pageExited(1) == [.showChrome, .toggleWindowFullScreen])
    }

    @Test func aPageThatIsNotShownIsAskedToLeave() {
        var state = PageFullscreen()
        #expect(state.pageEntered(2, isShown: false, windowIsFullScreen: false) == [.exitPage(2)])
        #expect(!state.isActive)
    }

    @Test func anotherShownPageTakesOverWithoutTogglingTheWindow() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        #expect(state.pageEntered(2, isShown: true, windowIsFullScreen: true) == [.exitPage(1)])
        #expect(state.tab == 2)
        #expect(state.pageExited(1) == [])
        #expect(state.pageExited(2) == [.showChrome, .toggleWindowFullScreen])
    }

    @Test func switchingTabsExitsThePageAndRestores() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        #expect(state.shownTabChanged(to: 1) == [])
        #expect(state.shownTabChanged(to: 2) == [.exitPage(1), .showChrome, .toggleWindowFullScreen])
        #expect(!state.isActive)
        #expect(state.shownTabChanged(to: 1) == [])
    }

    @Test func theLastTabClosingRestores() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: true)
        #expect(state.shownTabChanged(to: nil) == [.exitPage(1), .showChrome])
    }

    @Test func aGoneTabRestoresWithoutAskingItsPage() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        #expect(state.tabGone(2) == [])
        #expect(state.tabGone(1) == [.showChrome, .toggleWindowFullScreen])
        #expect(state.tabGone(1) == [])
    }

    @Test func leavingWindowFullScreenExitsThePageWithoutTogglingAgain() {
        var state = PageFullscreen()
        #expect(state.windowExitedFullScreen() == [])
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        #expect(state.windowExitedFullScreen() == [.exitPage(1), .showChrome])
        #expect(!state.isActive)
        #expect(state.pageExited(1) == [])
    }

    @Test func escapeIsClaimedOnlyInThePageFillingTheWindow() {
        var state = PageFullscreen()
        #expect(!state.claimsEscape(in: 1))
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        #expect(state.claimsEscape(in: 1))
        #expect(!state.claimsEscape(in: 2))
        _ = state.pageExited(1)
        #expect(!state.claimsEscape(in: 1))
    }

    @Test func chromeFollowsTheLayoutUntilAPageFillsTheWindow() {
        let sidebar = WindowChrome(layout: .sidebar, pageFullscreen: false)
        #expect(sidebar.showsSidebar && !sidebar.showsTopBar && sidebar.cardStyled)
        let top = WindowChrome(layout: .topTabs, pageFullscreen: false)
        #expect(!top.showsSidebar && top.showsTopBar && top.cardStyled)
        for layout in WindowLayout.allCases {
            let filled = WindowChrome(layout: layout, pageFullscreen: true)
            #expect(!filled.showsSidebar && !filled.showsTopBar && !filled.cardStyled)
        }
    }

    // MARK: macOS full screen transitions

    @Test func leavingDuringTheEnterTransitionTogglesOnceItEnds() {
        var state = PageFullscreen()
        #expect(
            state.pageEntered(1, isShown: true, windowIsFullScreen: false) == [.hideChrome, .toggleWindowFullScreen])
        state.windowWillEnterFullScreen()
        #expect(state.transition == .entering)
        // Escape while the window animates in: the chrome comes back now, the toggle waits.
        #expect(state.pageExited(1) == [.showChrome])
        #expect(state.queuedFullScreen == false)
        #expect(state.windowEnteredFullScreen() == [.toggleWindowFullScreen])
        #expect(state.transition == nil && state.queuedFullScreen == nil)
        // The exit that toggle starts ends with nothing left to do.
        state.windowWillExitFullScreen()
        #expect(state.windowExitedFullScreen() == [])
        #expect(!state.isActive)
    }

    @Test func leavingAndEnteringAgainDuringOneTransitionTogglesNothing() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        #expect(state.pageExited(1) == [.showChrome])
        // The window still reads as not in full screen, but it is heading there.
        #expect(state.pageEntered(1, isShown: true, windowIsFullScreen: false) == [.hideChrome])
        #expect(state.queuedFullScreen == nil)
        #expect(state.windowEnteredFullScreen() == [])
        #expect(state.isActive && state.enteredWindowFullScreen)
        #expect(state.pageExited(1) == [.showChrome, .toggleWindowFullScreen])
    }

    @Test func enterLeaveEnterLeaveDuringOneTransitionTogglesOnce() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        _ = state.pageExited(1)
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        #expect(state.tabGone(1) == [.showChrome])
        #expect(state.windowEnteredFullScreen() == [.toggleWindowFullScreen])
        #expect(state.windowEnteredFullScreen() == [])
    }

    @Test func enteringAgainDuringTheExitTransitionKeepsThePageAndGoesBackIn() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        _ = state.windowEnteredFullScreen()
        #expect(state.pageExited(1) == [.showChrome, .toggleWindowFullScreen])
        state.windowWillExitFullScreen()
        // The window still reads as in full screen, but it is heading out.
        #expect(state.pageEntered(1, isShown: true, windowIsFullScreen: true) == [.hideChrome])
        #expect(state.queuedFullScreen == true)
        // Our own exit ends: the page keeps the window, which goes back in.
        #expect(state.windowExitedFullScreen() == [.toggleWindowFullScreen])
        #expect(state.isActive && state.enteredWindowFullScreen)
    }

    @Test func leavingDuringAnExitTheSystemStartedQueuesNothing() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        _ = state.windowEnteredFullScreen()
        // The green button: the window animates out, and Escape lands meanwhile.
        state.windowWillExitFullScreen()
        #expect(state.pageExited(1) == [.showChrome])
        #expect(state.queuedFullScreen == nil)
        #expect(state.windowExitedFullScreen() == [])
    }

    @Test func aPageEnteringDuringAnEnterTheSystemStartedLeavesTheWindowThere() {
        var state = PageFullscreen()
        state.windowWillEnterFullScreen()
        #expect(state.pageEntered(1, isShown: true, windowIsFullScreen: false) == [.hideChrome])
        #expect(!state.enteredWindowFullScreen)
        #expect(state.windowEnteredFullScreen() == [])
        #expect(state.pageExited(1) == [.showChrome])
    }

    @Test func aFailedEnterLeavesTheWindowOutAndLeavingThenTogglesNothing() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        #expect(state.windowFailedToEnterFullScreen() == [])
        #expect(state.transition == nil)
        #expect(state.isActive && !state.enteredWindowFullScreen)
        #expect(state.pageExited(1) == [.showChrome])
    }

    @Test func aFailedEnterAfterThePageLeftTogglesNothing() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        _ = state.pageExited(1)
        #expect(state.windowFailedToEnterFullScreen() == [])
        // Later toggles go out at once again.
        #expect(
            state.pageEntered(1, isShown: true, windowIsFullScreen: false) == [.hideChrome, .toggleWindowFullScreen])
    }

    @Test func aFailedExitKeepsAPageThatAskedAgainAndTogglesNothing() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        _ = state.windowEnteredFullScreen()
        _ = state.pageExited(1)
        state.windowWillExitFullScreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: true)
        #expect(state.windowFailedToExitFullScreen() == [])
        #expect(state.transition == nil && state.queuedFullScreen == nil)
        #expect(state.isActive)
        #expect(state.pageExited(1) == [.showChrome, .toggleWindowFullScreen])
    }

    @Test func aTabGoneDuringTheEnterTransitionTakesTheWindowOutAfterwards() {
        var state = PageFullscreen()
        _ = state.pageEntered(1, isShown: true, windowIsFullScreen: false)
        state.windowWillEnterFullScreen()
        #expect(state.tabGone(1) == [.showChrome])
        #expect(state.windowEnteredFullScreen() == [.toggleWindowFullScreen])
    }

    @Test func theCardLosesItsInsetsOnlyWhileAPageFillsTheWindow() {
        for layout in WindowLayout.allCases {
            for toolbar in [true, false] {
                #expect(
                    WindowChrome.pageInsets(layout: layout, showsToolbar: toolbar, pageFullscreen: true) == (0, 0, 0, 0)
                )
                #expect(
                    WindowChrome.pageInsets(layout: layout, showsToolbar: toolbar, pageFullscreen: false)
                        == layout.pageInsets(showsToolbar: toolbar))
            }
        }
    }
}
