# Window look

## Summary

The browser window looks calm and minimal, the way Arc's does: one continuous surface holds the sidebar and the window buttons, and the page sits on it as a card.
It uses Bow's brand colors as light and dark tokens, soft radii and one soft shadow, with the system font, so it feels native on the Mac.

## Behavior

- The window is one Frame colored surface from its top edge down: the title bar is transparent, there is no toolbar band, the sidebar runs to the top, and the close, minimize and zoom buttons sit in it.
- The sidebar is 264 points wide, padded 14 points at the top and leading edge and 12 at the trailing and bottom edges.
- The sidebar's top row, level with the window buttons, holds Back, Forward and Reload as plain 17 point icons in Soft, right aligned.
- Below the top row sits the URL field, as in Arc: 36 points tall across the sidebar's padding, 10 point continuous corners, the Active fill, and 12 points of padding with 8 between a 13 point lock symbol in Soft and one line of text in the UI font, cut at its end when it does not fit.
  The lock is decoration for now; it does not open site settings.
  It shows the shown tab's site the way Arc's sidebar URL bar does: the host without the scheme or a leading `www.`, then the path unless it is just `/`, never the query or the fragment (`notes.example.com/roadmap`; a trailing slash on a deeper path is dropped), with a port only when it is not the scheme's default (`localhost:3000`); a local file shows its file name.
  A blank tab, an internal page, a `data:` address or an empty Space shows "Search or type a URL" in Soft.
  It follows the shown tab: switching tabs or Spaces, a navigation, a redirect or a page changing its own address updates it.
  A click on it opens the command bar on the current address, as Cmd+L does; the full address is always one click or Cmd+L away.
- View > Hide Toolbar (Cmd+Shift+D, the name and keys of Arc's View > Show Toolbar) hides the top row's Back, Forward and Reload and the URL field for the most minimal chrome, and the sidebar's content rises to just under the title bar; the window buttons stay, and the item then reads Show Toolbar and brings them back.
  Cmd+L still shows the address in the command bar while they are hidden, and the shortcut is taken before the page, as Cmd+L is.
  The choice is one app setting: every open window follows it at once, a new window opens with it, and it is kept across quit and relaunch.
- The page is a White card inset 8 points from the frame at the top, trailing and bottom edges (the sidebar side meets the sidebar), with 10 point continuous rounded corners and one soft shadow (1 point down, 3 point blur, 14 percent Night).
- A click near the card's top edge reaches the page.
- Pressing and dragging on the frame around the card (its 8 point inset) or on the sidebar's empty top area moves the window, as a title bar does; the card itself and every control keep their clicks, so the card's top edge does not drag the window.
- Favorites are tiles 44 points tall in 4 equal columns 8 points apart, filling the sidebar between its padding (about 53.5 points wide at 264), with 10 point corners in Pin; site icons are 20 points.
- The Space name is a group label below the Favorites and above the Space's tabs, as in Arc: 11 point bold uppercase in Soft, with letter spacing, inset 10 points within the sidebar's padding.
  It is a row of the list and scrolls with the tabs.
- Tab rows are 34 points tall with 15 point site icons and 10 points between icon and title; rows inside a folder are 32 points tall and step in 22 points per level, so their icons sit under the folder's name, while rows directly under the Space name keep their place.
- The active tab's row is lifted: Active fill, 9 point corners, the soft shadow and a bold title; a hovered row is tinted Pin; other rows have no background.
- Folder rows show a chevron and a semibold name.
- The line between pinned and today tabs is a Line colored rule inset 10 points within the sidebar's padding.
- The footer holds the downloads and archive buttons on the left, the Space dots centred in the space between them and the "+" for a new Space on the right.
  Each Space shows one 14 point dot, the one on screen with an Apricot ring (a 2 point gap in the frame color, then a 2 point ring).
  A Space with a theme shows its theme color; the default theme keeps today's colors: Jam on screen, Soft otherwise.
  A dot's context menu offers Rename and Delete Space, then Theme (Default and the presets, the Space's own checked), Change Icon and Remove Icon, the same items as the Space name's menu.
- The start screen's hint reads "<Space> · press ⌘T to search", with no tab count, since the screen only shows in an empty Space; the card stays White in dark appearance.
- The command bar is a White panel with 14 point corners, which clip its field and results, and the soft shadow, centered over the card.
- An empty Space shows the start screen (`start-screen.md`): the Bow mark at 64 points, the greeting, the search pill, the quick links and the hint, 26 points apart.
- The unloaded tab state shows the Bow mark at 64 points above its line in Soft and a Jam Deep pill button with white text.
- The app icon is Bow's light app tile; the About panel shows it, since it shows the app icon.
- In dark mode the frame is Night, the active row and Favorites take their dark tokens, and text is Cream; the card and the command bar stay White and draw light.
- Sidebar, command bar and empty state text use Nunito Sans: 13.5 points for UI text (tab and folder rows, New Tab, the empty state's button), the group label 11 points bold with letter spacing 0.8, the active row bold (700), folder rows semibold (600), and the command bar's own sizes unchanged.
  The fonts are the brand kit's variable TTFs, bundled in Resources/Fonts and registered at launch by `ATSApplicationFontsPath` in Info.plist; their SIL Open Font Licenses are in the About panel's licenses.
  A font that fails to load falls back to the system font in the same size and weight.
- Fredoka 600 at 40 points (`BowBrand.display()`) is the start screen greeting's font, its only use; the start screen's hint is 13 points and its placeholder 16 points in Nunito Sans. JetBrains Mono is not bundled.
- Other windows (downloads, permission prompts, find bar, About panel) keep the system font.
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
5. Switch to an empty Space: the start screen shows the Bow mark at 24 points or more.
6. With a Favorite and a pinned folder of two tabs: the first tile starts 14 points in and is 53.5 by 44 points (4 columns), a tab inside the folder has its icon 22 points right of a tab directly in the Space with that tab's icon where it was (43 points in), and its row is 32 points tall; the Space name sits below the Favorites and above the first tab row; the active Space's dot is 14 points with a 2 point gap and a 2 point #FFC08A ring.
7. Open the command bar: its panel's content is clipped to 14 point corners, and its shadow has a path the size of the panel.
8. Switch the window to dark: the frame is #2A1710, the active row #3D2519 and its title #FFF3E6, and the navigation buttons draw dark.
9. The app bundle names its icon (CFBundleIconName AppIcon) and carries AppIcon.icns.
10. Open a window on a page: the URL field below the top row reads the page's site, is 238 by 36 points and clears the window buttons; open a blank tab and it reads "Search or type a URL"; go back to the page, let the page send itself to a blank page and load it again, and the field follows each change; click the field and the command bar opens on the full address, selected (`make e2e E2E=chrome` prints `PASS chrome.url-field`, `chrome.url-field.follows` and `chrome.url-field.click`).
11. Choose View > Hide Toolbar: the top row and the URL field hide, the item reads Show Toolbar, the setting is saved, a new window opens without them, and Cmd+L still opens the command bar on the address; Show Toolbar brings both back at full width (`PASS chrome.toolbar-hidden`, `chrome.toolbar-hidden.cmd-l` and `chrome.toolbar-hidden.show`).
12. `design.fonts` prints PASS for `design.fonts_registered`, `design.fonts_sidebar`, `design.fonts_command_bar` and `design.fonts_empty`.
13. `make e2e E2E=design` runs these checks and writes screenshots to `build/e2e/<run>/design/`, among them `mockup-1.png` (start screen, light), `mockup-2.png` (browsing, light), `mockup-3.png` (browsing, dark) and `mockup-4.png` (top tabs), as evidence for the maintainer to look at, never compared by pixels.
14. `design.footer` prints PASS for `design.footer_centred` (the dots' middle is within 1 point of the middle between the archive button and the "+"), `design.footer_dot_colors` and `design.footer_dot_menu`; `design.fonts` also reads the folder rows (semibold) and the command bar's result rows.

## Out of scope

- A downloads button in the footer, and moving New Tab to the end of the tab list: each is later work.
- The lock symbol opening site settings, and showing the full address in the URL field.
- Revealing the hidden toolbar at the window's edge, hiding the sidebar, per Space colors, themes, animations and settings.
- A dark app tile as an icon appearance variant: on macOS it needs an Icon Composer icon, not an asset catalog app icon set.

## Sources

- Bow brand kit: the Apricot Jam palette, "round everything, no hard shadows", "only the logo tilts", the mark's minimum of 24 px in UI.
- Apple Human Interface Guidelines, Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Apple, configuring an app icon in an asset catalog (dark and tinted variants are iOS and iPadOS only; macOS uses Icon Composer for them): https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- Apple, CALayer shadowPath (an explicit path improves shadow rendering): https://developer.apple.com/documentation/quartzcore/calayer/shadowpath
- Apple, CALayerCornerCurve.continuous: https://developer.apple.com/documentation/quartzcore/calayercornercurve/continuous
- Apple, Core Animation layer style properties (a corner radius clips content only with masksToBounds, which also clips the shadow, so the shadow sits on a separate view): https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/LayerStyleProperties/LayerStyleProperties.html
- Arc's View > Show Toolbar and its Command-Shift-D shortcut: https://resources.arc.net/hc/en-us/articles/25625458052247-How-Do-You-View-the-Full-URL-at-the-Top-of-the-Page-in-Arc-for-Desktop and https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes
- Arc's sidebar URL bar shows the site rather than the full address, which is why Arc documents a way to see the full URL (same help article).
- An Arc style window reference (tinted frame, the page inset about 8 px on three sides with rounded corners): https://deviceshots.com/browsers/arc/
