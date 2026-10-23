# Window look

## Summary

The browser window looks calm and minimal, the way Arc's does: one continuous surface holds the sidebar and the window buttons, and the page sits on it as a card.
It uses Bow's brand (the Apricot Jam palette, soft radii, no hard edges) and the system font, so it feels native on the Mac.

## Behavior

- The window is one Cream surface from its top edge down: the title bar is transparent, the sidebar runs to the top, and the close, minimize and zoom buttons sit over the sidebar.
- The back, forward and reload buttons stay beside the window buttons, on the same surface; there is no separate white toolbar band.
- The page is a White card below the title bar, inset 8 points from the window's trailing and bottom edges, with 14 point continuous rounded corners and one soft shadow (low opacity, large blur, small downward offset).
- The card's top follows the title bar's height, so it stays below the toolbar in a normal window and in full screen.
- The active tab's row is a lifted White row with 14 point rounded corners, Cocoa text and a very light shadow.
- Hovering a row tints it Crust; other rows have no background, and no title is shown in blue.
- The line between pinned and today tabs is a short Crust line inset from both sides of the sidebar.
- The Space name, New Tab and the Space switcher use Cocoa and Cocoa Soft, spaced on the 4, 8, 12 and 16 point scale.
- The empty Space and unloaded tab states show the Bow mark at 64 points above their line and button, on the White card.
- The app icon is Bow's light app tile; the About panel shows it, since it shows the app icon.
- In dark mode the frame is Night, the card and the active row are Cocoa, and text is Cream; the Bow mark switches to its version for dark grounds.
- All UI text uses the system font; Bow's brand fonts are not bundled.
- Colors and radii come from one file of named values, copied from the brand kit's tokens.

## Edge cases

- A narrow window keeps the sidebar's width; the card shrinks with its corners, inset and shadow.
- A page with its own dark background shows inside the card's rounded corners, which clip it.
- The command bar opens centered over the card.
- A Favorite that is the active tab shows in the Favorites grid; no tab row is lifted then.
- The window's buttons follow the window's light or dark appearance.

## Acceptance checks

1. Open a window on a page: the title bar is transparent with full size content, the window buttons sit over the sidebar, and the frame is Cream (#FFF3E6).
2. The page card is inset by the title bar's height at the top, 0 at the sidebar and 8 at the trailing and bottom edges, with a 14 point continuous radius and a shadow whose opacity is above 0 and below 0.3.
3. The active row's background is White (#FFFFFF) and its title Cocoa (#3A1F14).
4. Resize the window: the shadow stays exactly behind the card.
5. Switch to an empty Space: the empty state shows the Bow mark at 24 points or more.
6. Switch the window to dark: the frame is Night (#2A1710), the active row Cocoa and its title Cream (#FFF3E6).
7. The app bundle names its icon (CFBundleIconName AppIcon) and carries AppIcon.icns.
8. `make e2e E2E=design` runs these checks and writes screenshots to `build/e2e/<run>/design/`.

## Out of scope

- Hiding the toolbar and the URL bar (a later item).
- A dark app tile as an icon appearance variant: on macOS it needs an Icon Composer icon, not an asset catalog app icon set.
- Animations, per Space colors, themes and settings.

## Sources

- Bow brand kit: palette, radii 14, 24 and pill, the 4 to 96 spacing scale, "round everything, no hard shadows", "only the logo tilts", the mark's minimum of 24 px in UI.
- Apple Human Interface Guidelines, Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Apple, configuring an app icon in an asset catalog (dark and tinted variants are iOS and iPadOS only; macOS uses Icon Composer for them): https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- Apple, CALayer shadowPath (an explicit path improves shadow rendering): https://developer.apple.com/documentation/quartzcore/calayer/shadowpath
- Apple, CALayerCornerCurve.continuous: https://developer.apple.com/documentation/quartzcore/calayercornercurve/continuous
- Apple, Core Animation layer style properties (a corner radius clips content only with masksToBounds, which also clips the shadow, so the shadow sits on a separate layer): https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/LayerStyleProperties/LayerStyleProperties.html
- Arc's window as described by an Arc style mockup reference (tinted frame, the page inset about 8 px on three sides with rounded corners): https://deviceshots.com/browsers/arc/
