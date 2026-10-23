import BowCore
import Testing

@Suite struct KeyShortcutsTests {
    func key(
        _ characters: String, _ modifiers: KeyModifiers, keyCode: Int = 0, kind: EngineKeyEvent.Kind = .keyDown,
        editable: Bool = false
    ) -> EngineKeyEvent {
        EngineKeyEvent(
            kind: kind, keyCode: keyCode, characters: characters, charactersIgnoringModifiers: characters,
            modifiers: modifiers, isInEditableField: editable)
    }

    @Test func noKeyIsClaimedTwice() {
        let conflicts = KeyShortcuts.conflicts()
        #expect(conflicts.isEmpty, "\(conflicts)")
    }

    @Test func aDuplicateClaimIsAConflict() {
        let claims = KeyShortcuts.claims + [KeyShortcutClaim(.changeURL, .toolbar)]
        let conflicts = KeyShortcuts.conflicts(in: claims)
        #expect(conflicts.map(\.chord) == [.character("l", .command)])
        #expect(conflicts.first?.description == "Cmd+L is claimed by commandBar.changeURL, toolbar.changeURL")
    }

    @Test func everyShortcutIsClaimedOnce() {
        let claimed = KeyShortcuts.claims.map(\.shortcut)
        // A shared shortcut is claimed once per owner.
        let unshared = claimed.filter { !KeyShortcuts.sharedShortcuts.contains($0) }
        #expect(Set(unshared).count == unshared.count)
        #expect(Set(claimed) == Set(KeyShortcut.allCases))
    }

    @Test func arcShortcutsMatchTheirKeys() {
        #expect(KeyShortcut.newTab.matches(key("t", .command)))
        #expect(KeyShortcut.changeURL.matches(key("l", .command)))
        // With Shift held the character arrives uppercase.
        #expect(KeyShortcut.copyURL.matches(key("C", [.command, .shift])))
        #expect(KeyShortcut.toggleToolbar.matches(key("D", [.command, .shift])))
        #expect(KeyShortcut.zoomIn.matches(key("=", .command)))
        #expect(KeyShortcut.zoomIn.matches(key("+", .command)))
        // Arc's Command-Shift-Plus adds a split view, so it is no longer Zoom In.
        #expect(!KeyShortcut.zoomIn.matches(key("+", [.command, .shift])))
        #expect(KeyShortcut.addSplitView.matches(key("+", [.command, .shift])))
        #expect(KeyShortcut.addSplitView.matches(key("=", [.command, .shift])))
        #expect(!KeyShortcut.addSplitView.matches(key("=", .command)))
        #expect(KeyShortcut.zoomOut.matches(key("-", .command)))
        #expect(KeyShortcut.actualSize.matches(key("0", .command)))
        #expect(KeyShortcut.recentTabs.matches(key("\t", .control, keyCode: KeyChord.tabKeyCode)))
        #expect(KeyShortcut.closeCommandBar.matches(key("\u{1b}", [], keyCode: KeyChord.escapeKeyCode)))
        #expect(KeyShortcut.closeCommandBar.chords.first?.description == "Esc")
    }

    @Test func modifiersMustMatchExactly() {
        #expect(!KeyShortcut.changeURL.matches(key("l", [])))
        #expect(!KeyShortcut.changeURL.matches(key("l", [.command, .option])))
        #expect(!KeyShortcut.copyURL.matches(key("c", .command)))
        #expect(!KeyShortcut.toggleToolbar.matches(key("d", .command)))
        #expect(!KeyShortcut.closeCommandBar.matches(key("\u{1b}", .shift, keyCode: KeyChord.escapeKeyCode)))
        #expect(!KeyShortcut.recentTabs.matches(key("\t", [.control, .shift], keyCode: KeyChord.tabKeyCode)))
    }

    @Test func recentTabsKeysAndSharedEscape() {
        #expect(KeyShortcut.recentTabsBack.matches(key("\t", [.control, .shift], keyCode: KeyChord.tabKeyCode)))
        #expect(
            KeyShortcuts.shortcut(for: key("\u{1b}", [], keyCode: KeyChord.escapeKeyCode), claimedBy: .recentTabs)
                == .closeCommandBar)
        #expect(
            KeyShortcuts.shortcut(for: key("\u{1b}", [], keyCode: KeyChord.escapeKeyCode), claimedBy: .peek)
                == .closeCommandBar)
        #expect(KeyShortcuts.conflicts().isEmpty)
        let twice = KeyShortcuts.claims + [KeyShortcutClaim(.closeCommandBar, .recentTabs)]
        #expect(!KeyShortcuts.conflicts(in: twice).isEmpty)
    }

    @Test func pageFullscreenSharesEscapeWithTheOverlaysOnly() {
        let escape = key("\u{1b}", [], keyCode: KeyChord.escapeKeyCode)
        #expect(KeyShortcuts.shortcut(for: escape, claimedBy: .pageFullscreen) == .exitPageFullscreen)
        #expect(KeyShortcuts.shortcut(for: escape, claimedBy: .commandBar) == .closeCommandBar)
        #expect(KeyShortcuts.conflicts().isEmpty)
        // Page fullscreen claiming an unshared key someone else holds still conflicts.
        let unshared = KeyShortcuts.claims + [KeyShortcutClaim(.newTab, .pageFullscreen)]
        #expect(KeyShortcuts.conflicts(in: unshared).map(\.chord) == [.character("t", .command)])
    }

    @Test func onlyKeyDownsMatch() {
        #expect(!KeyShortcut.changeURL.matches(key("l", .command, kind: .keyUp)))
        #expect(!KeyShortcut.changeURL.matches(key("l", .command, kind: .character)))
    }

    @Test func aFeatureGetsOnlyTheShortcutsItClaims() {
        #expect(KeyShortcuts.shortcut(for: key("l", .command), claimedBy: .commandBar) == .changeURL)
        #expect(KeyShortcuts.shortcut(for: key("l", .command), claimedBy: .zoom) == nil)
        #expect(KeyShortcuts.shortcut(for: key("0", .command), claimedBy: .zoom) == .actualSize)
        #expect(KeyShortcuts.shortcut(for: key("x", .command), claimedBy: .commandBar) == nil)
    }
}
