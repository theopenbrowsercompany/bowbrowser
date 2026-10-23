# Window look

## Summary

The browser window looks calm and minimal, the way Arc's does: one continuous surface holds the sidebar and the window buttons, and the page sits on it as a card.
It uses Bow's brand colors as light and dark tokens, soft radii and one soft shadow, with the system font, so it feels native on the Mac.

## Behavior

- The window is one Frame colored surface from its top edge down: the title bar is transparent, there is no toolbar band, the sidebar runs to the top, and the close, minimize and zoom buttons sit in it.
- The sidebar is 264 points wide, padded 14 points at the top and leading edge and 12 at the trailing and bottom edges.
- The sidebar's top row, level with the window buttons, holds Back, Forward and Reload as plain 17 point icons in Soft, right aligned.
- The page is a White card inset 8 points from the frame at the top, trailing and bottom edges (the sidebar side meets the sidebar), with 10 point continuous rounded corners and one soft shadow (1 point down, 3 point blur, 14 percent Night).
- A click near the card's top edge reaches the page.
- Favorites are 44 point tall tiles, 4 to a row, 8 points apart, with 10 point corners in Pin; site icons are 20 points.
- The Space name is a group label: 11 point bold uppercase in Soft, with letter spacing.
- Tab rows are 34 points tall with 15 point site icons and 10 points between icon and title; rows inside a folder are 32 points tall.
- The active tab's row is lifted: Active fill, 9 point corners, the soft shadow and a bold title; a hovered row is tinted Pin; other rows have no background.
- Folder rows show a chevron and a semibold name.
- The line between pinned and today tabs is a short Line colored rule.
- The Space switcher shows one 14 point dot per Space, the one on screen in Jam with an Apricot ring (a 2 point gap, then a 4 point ring), the others in Soft, and a "+" for a new Space.
- The command bar is a White panel with 14 point corners and the soft shadow, centered over the card.
- The empty Space and unloaded tab states show the Bow mark at 64 points above their line in Soft and a Jam Deep pill button with white text.
- The app icon is Bow's light app tile; the About panel shows it, since it shows the app icon.
- In dark mode the frame is Night, the active row and Favorites take their dark tokens, and text is Cream; the card and the command bar stay White and draw light.
- All UI text uses the system font.
- The tokens, radii, shadow and sidebar spacing come from one file of named values.

## Edge cases

- A narrow window keeps the sidebar's width; the card shrinks with its corners, inset and shadow.
- A page with its own dark background shows inside the card's rounded corners, which clip it.
- A Favorite that is the active tab shows as a lifted tile in the grid; no tab row is lifted then.
- The navigation buttons follow the window's light or dark appearance.

## Acceptance checks

1. Open a window on a page: the title bar is transparent with full size content and no toolbar, the window buttons sit over the 264 point sidebar, and Back, Forward and Reload sit in its top row level with them.
2. The page card's insets are 8, 0, 8 and 8 (top, sidebar, bottom, trailing), its radius 10 and continuous, a click 4 points below its top reaches the page, and its shadow is about 14 percent.
3. The frame is #FFF3E6; the active row is #FFFFFF, 34 points tall with a 9 point radius, a shadow and a bold #3A1F14 title.
4. Resize the window: the shadow stays exactly behind the card.
5. Switch to an empty Space: the empty state shows the Bow mark at 24 points or more.
6. Switch the window to dark: the frame is #2A1710, the active row #3D2519 and its title #FFF3E6, and the navigation buttons draw dark.
7. The app bundle names its icon (CFBundleIconName AppIcon) and carries AppIcon.icns.
8. `make e2e E2E=design` runs these checks and writes screenshots to `build/e2e/<run>/design/`.

## Out of scope

- A URL field in the sidebar, a downloads button in the footer, a start screen with a greeting, search field and quick links, bundled brand fonts, and moving New Tab to the end of the tab list: each is later work.
- Hiding the sidebar or the navigation buttons, per Space colors, themes, animations and settings.
- A dark app tile as an icon appearance variant: on macOS it needs an Icon Composer icon, not an asset catalog app icon set.

## Sources

- Bow brand kit: the Apricot Jam palette, "round everything, no hard shadows", "only the logo tilts", the mark's minimum of 24 px in UI.
- Apple Human Interface Guidelines, Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Apple, configuring an app icon in an asset catalog (dark and tinted variants are iOS and iPadOS only; macOS uses Icon Composer for them): https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- Apple, CALayer shadowPath (an explicit path improves shadow rendering): https://developer.apple.com/documentation/quartzcore/calayer/shadowpath
- Apple, CALayerCornerCurve.continuous: https://developer.apple.com/documentation/quartzcore/calayercornercurve/continuous
- Apple, Core Animation layer style properties (a corner radius clips content only with masksToBounds, which also clips the shadow, so the shadow sits on a separate view): https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/LayerStyleProperties/LayerStyleProperties.html
- An Arc style window reference (tinted frame, the page inset about 8 px on three sides with rounded corners): https://deviceshots.com/browsers/arc/
