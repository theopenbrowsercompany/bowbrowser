# Window look

## Summary

The browser window looks calm and minimal, the way Arc's does: one continuous surface holds the sidebar and the window buttons, and the page sits on it as a card.
It uses Bow's brand colors as light and dark tokens, soft radii and one soft shadow, with the brand's UI font, so it feels native on the Mac.
Each surface has its own heading below (frame, sidebar, Favorites, footer, command bar, start screen), and its e2e checks live in the matching `E2E/Tests/Design<Surface>.swift`.

## Behavior

### Frame

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
- The app icon is Bow's light app tile; the About panel shows it, since it shows the app icon.
- In dark mode the frame is Night, the active row and Favorites take their dark tokens, and text is Cream; the card and the command bar stay White and draw light.
- Sidebar, command bar and empty state text use Nunito Sans (each surface below gives its sizes).
  The fonts are the brand kit's variable TTFs, bundled in Resources/Fonts and registered at launch by `ATSApplicationFontsPath` in Info.plist; their SIL Open Font Licenses are in the About panel's licenses.
  A font that fails to load falls back to the system font in the same size and weight.
  JetBrains Mono is not bundled.
  Other windows (downloads, permission prompts, find bar, About panel) keep the system font.
- The tokens, radii, shadow and sidebar spacing come from one file of named values.
- Page fullscreen: when a page asks to fill the screen (a video's fullscreen button, `element.requestFullscreen()`), the page gets the whole window, as in Chrome and Arc.
  The sidebar (or, in the top tabs layout, the tab strip and toolbar row) hides, the card loses its inset, corners and shadow, and the window enters macOS full screen.
  Escape (which the page then never sees), the page's own `document.exitFullscreen()`, leaving macOS full screen, switching tabs, closing the tab or the page navigating to another document leave page fullscreen and bring back the layout as it was, and take the window out of macOS full screen.
  A window that was already in macOS full screen before the page asked stays there; only the chrome and the card come back.
- Plain macOS full screen (with no page fullscreen) keeps the sidebar and the card's inset, corners and shadow, as Arc does; Arc drops the border only when its sidebar is hidden too, which Bow does not offer yet.

### Sidebar

- The Space name is a group label below the Favorites and above the Space's tabs, as in Arc: 11 point bold uppercase in Soft, with letter spacing 0.8, inset 10 points within the sidebar's padding.
  It is a row of the list and scrolls with the tabs.
- Tab rows are 34 points tall with 15 point site icons and 10 points between icon and title; rows inside a folder are 32 points tall and step in 22 points per level, so their icons sit under the folder's name, while rows directly under the Space name keep their place.
- The active tab's row is lifted: Active fill, 9 point corners, the soft shadow and a bold title; a hovered row is tinted Pin; other rows have no background.
- Folder rows show a chevron and a semibold name.
- The line between pinned and today tabs is a Line colored rule inset 10 points within the sidebar's padding.
- Row text (tab and folder rows, New Tab) is 13.5 point Nunito Sans, the active row bold (700) and folder rows semibold (600).

### Favorites

- Favorites are tiles 44 points tall in 4 equal columns 8 points apart, filling the sidebar between its padding (about 53.5 points wide at 264), with 10 point corners in Pin; site icons are 20 points.

### Footer

- The footer holds the downloads and archive buttons on the left, the Space dots centred in the space between them and the "+" for a new Space on the right.
  Each Space shows one 14 point dot, the one on screen with an Apricot ring (a 2 point gap in the frame color, then a 2 point ring).
  A Space with a theme shows its theme color; the default theme keeps today's colors: Jam on screen, Soft otherwise.
  A dot's context menu offers Rename and Delete Space, then Theme (Default and the presets, the Space's own checked), Change Icon and Remove Icon, the same items as the Space name's menu.

### Command bar

- The command bar is a White panel with 14 point corners, which clip its field and results, and the soft shadow, centered over the card.
- Its field is 20 point Nunito Sans, its result titles 14 points and their details 12 points.

### Start screen and empty state

- An empty Space shows the start screen (`start-screen.md`): the Bow mark at 64 points, the greeting, the search pill, the quick links and the hint, 26 points apart.
- The start screen's hint reads "<Space> · press ⌘T to search", with no tab count, since the screen only shows in an empty Space; the card stays White in dark appearance.
- Fredoka 600 at 40 points (`BowBrand.display()`) is the start screen greeting's font, its only use; the start screen's hint is 13 points and its placeholder 16 points in Nunito Sans.
- The unloaded tab state shows the Bow mark at 64 points above its line in Soft and a Jam Deep pill button with white text, in 13.5 point Nunito Sans.

## Edge cases

- A narrow window keeps the sidebar's width; the card shrinks with its corners, inset and shadow.
- A page with its own dark background shows inside the card's rounded corners, which clip it.
- A Favorite that is the active tab shows as a lifted tile in the grid; no tab row is lifted then.
- The navigation buttons follow the window's light or dark appearance.
- A second fullscreen request from the page already filling the window changes nothing; a page in a tab that is not shown is asked to leave at once.
- Closing the window or quitting while a page is fullscreen closes it without toggling macOS full screen first.
- macOS ignores a full screen toggle sent while the window is still animating into or out of full screen, so page fullscreen waits for the animation to end.
  The chrome and the card follow at once; the window is toggled when the animation ends (did enter or did exit full screen), at most once, and only when it did not end where the page wants it.
  Escape right after entering takes the window out once the enter animation ends; entering, leaving and entering again during one animation toggles nothing more; a page that asks again while the window animates out of full screen keeps the window, which goes back in.
- A window that fails to enter macOS full screen keeps the page filling it, and leaving then brings the chrome back without a toggle; a window that fails to leave stays in full screen, and Bow does not try again.

## Design captures

- The design tests start from one fixed fixture, so captures read the same whatever the hour, the run or the screen: the Spaces 🏠 Home (default theme) and 💼 Work (the Blue preset), six Favorites, a pinned tab, a pinned folder of two and three today tabs in Home and two today tabs in Work, each fixture page linking its own icon from `https://bow.test/design/icons/`, a start screen clock fixed at 10:00 through BowCore's `TimeSource`, and a 1200 by 800 point window showing Home's Notes.
- `design.screens` writes named captures to `build/e2e/<run>/design/` for the maintainer to look at: `browsing-light.png`, `browsing-dark.png`, `browsing-blue.png` (the Work Space), `command-bar.png`, `empty-space.png` and `top-tabs.png` of the 1200 by 800 point window, `narrow.png` of a 640 by 560 window, and `sidebar-light.png` and `sidebar-dark.png` of the sidebar's column from the window's top to its bottom; `design.start_screen` adds `start-screen.png`, `start-narrow.png` and `start-dark.png`.
- Every capture is drawn at 2 pixels per point on any screen (the 1200 by 800 window is 2400 by 1600 pixels), with the pointer parked off the sidebar (no hover) and the text caret hidden.
- A capture is evidence, never a pass or a failure: one that cannot be taken or written prints `NOTE design capture <name>: <why>` and the test goes on to its value checks; nothing compares capture pixels against a baseline.

## Acceptance checks

### Frame (`design.frame`)

1. Open a window on a page: the title bar is transparent with full size content and no toolbar, the window buttons sit over the 264 point sidebar, and Back, Forward and Reload sit in its top row level with them (`design.title_bar`, `design.sidebar_top_row`).
2. The page card's insets are 8, 0, 8 and 8 (top, sidebar, bottom, trailing), its radius 10 and continuous, a click 4 points below its top reaches the page, and its shadow is about 14 percent (`design.page_card`, `design.page_shadow`).
3. The frame is #FFF3E6 (`design.frame_color`).
4. Resize the window: the shadow stays exactly behind the card (`design.shadow_follows_resize`).
5. The app bundle names its icon (CFBundleIconName AppIcon) and carries AppIcon.icns (`design.app_icon`).
6. The app registered the bundled Nunito Sans and Fredoka, carries no JetBrains Mono, and has their files and licenses in Resources (`design.fonts_registered`).
7. Open a window on a page: the URL field below the top row reads the page's site, is 238 by 36 points and clears the window buttons; open a blank tab and it reads "Search or type a URL"; go back to the page, let the page send itself to a blank page and load it again, and the field follows each change; click the field and the command bar opens on the full address, selected (`make e2e E2E=chrome` prints `PASS chrome.url-field`, `chrome.url-field.follows` and `chrome.url-field.click`).
8. Choose View > Hide Toolbar: the top row and the URL field hide, the item reads Show Toolbar, the setting is saved, a new window opens without them, and Cmd+L still opens the command bar on the address; Show Toolbar brings both back at full width (`PASS chrome.toolbar-hidden`, `chrome.toolbar-hidden.cmd-l` and `chrome.toolbar-hidden.show`).
9. Click a page's fullscreen button: `make e2e E2E=fullscreen` prints `PASS fullscreen: sidebar=hidden` with insets 0, radius 0, no shadow and one full screen toggle, and PASS for `fullscreen.escape`, `fullscreen.exit`, `fullscreen.tab_switch`, `fullscreen.already`, `fullscreen.navigate`, `fullscreen.window_exit`, `fullscreen.top_tabs`, `fullscreen.transition` (Escape during the enter animation: one toggle until it ends, then exactly one exit toggle, with the chrome and card restored) and `fullscreen.transition_cancel` (Fullscreen, Escape and Fullscreen again during one animation: no toggle beyond the first) and `fullscreen.transition_failed` (a failed enter keeps the page filling the window, Escape brings the chrome back without a toggle, and the next Fullscreen toggles at once); a recorder stands in for macOS full screen, so the run never takes over the display.

### Sidebar (`design.sidebar`)

1. The active row is #FFFFFF, 34 points tall with a 9 point radius, a shadow and a bold #3A1F14 title (`design.selected_row`).
2. With a pinned folder of two tabs: a tab inside the folder has its icon 22 points right of a tab directly in the Space, with that tab's icon where it was (43 points in), and its row is 32 points tall (`design.folder_indent`).
3. The Space name sits below the Favorites and above the first tab row (`design.space_label`).
4. The active row is 13.5 point Nunito Sans bold, the Space name 11 point bold and folder rows 13.5 point semibold (`design.fonts_sidebar`).

### Favorites (`design.favorites`)

1. With six Favorites: the first tile starts 14 points in and is 53.5 by 44 points, in 4 columns, and the grid shows six tiles (`design.favorites`).

### Footer (`design.footer`)

1. The active Space's dot is 14 points with a 2 point gap and a 2 point #FFC08A ring (`design.space_dot`).
2. The dots' middle is within 1 point of the middle between the archive button and the "+", with the downloads and archive buttons left of the dots and the "+" right of them (`design.footer_centred`).
3. The dots are Jam on screen and Soft otherwise; theming the Space Blue turns its dot #3B5BDB and keeps the Apricot ring (`design.footer_dot_colors`).
4. The active dot's menu lists Rename and Delete Space, Theme with Default and the presets, Change Icon and Remove Icon (`design.footer_dot_menu`).

### Command bar (`design.command_bar`)

1. Open the command bar: its panel's content is clipped to 14 point corners, and its shadow has a path the size of the panel (`design.command_bar`).
2. Type in it: the field is 20 point Nunito Sans, result titles 14 points and details 12 points (`design.fonts_command_bar`).

### Start screen (`design.start_screen`)

1. Switch to an empty Space: the start screen shows the Bow mark at 24 points or more (`design.empty_mark`) and its hint in 13 point Nunito Sans (`design.fonts_empty`).
2. The rest of the start screen's checks are in `start-screen.md`.

### Captures and dark appearance (`design.screens`)

1. The window opens on the fixed fixture: the two Spaces with their icons and themes, the six Favorites, the pinned tab, the folder of two and the today tabs, Notes shown with its icon in the sidebar, its page linking `https://bow.test/design/icons/notes.png` (served as `image/png`), and the empty Space greeting "Good morning" for the fixed 10:00 (`design.fixture`).
2. The sidebar captured twice gives identical bitmaps (`design.capture_stable`).
3. Switch the window to dark: the frame is #2A1710, the active row #3D2519 and its title #FFF3E6, and the navigation buttons draw dark (`design.dark_colors`).
4. `make e2e E2E=design.screens` writes the captures the Design captures section lists to `build/e2e/<run>/design/`, as evidence for the maintainer, never compared by pixels; a capture it cannot write prints a NOTE and fails nothing.

## Out of scope

- A downloads button in the footer, and moving New Tab to the end of the tab list: each is later work.
- The lock symbol opening site settings, and showing the full address in the URL field.
- Revealing the hidden toolbar at the window's edge, hiding the sidebar, per Space colors, themes, animations and settings.
- A dark app tile as an icon appearance variant: on macOS it needs an Icon Composer icon, not an asset catalog app icon set.
- Pixel baselines for the design captures.

## Sources

- Bow brand kit: the Apricot Jam palette, "round everything, no hard shadows", "only the logo tilts", the mark's minimum of 24 px in UI.
- Apple Human Interface Guidelines, Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- Apple, configuring an app icon in an asset catalog (dark and tinted variants are iOS and iPadOS only; macOS uses Icon Composer for them): https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- Apple, CALayer shadowPath (an explicit path improves shadow rendering): https://developer.apple.com/documentation/quartzcore/calayer/shadowpath
- Apple, CALayerCornerCurve.continuous: https://developer.apple.com/documentation/quartzcore/calayercornercurve/continuous
- Apple, Core Animation layer style properties (a corner radius clips content only with masksToBounds, which also clips the shadow, so the shadow sits on a separate view): https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/LayerStyleProperties/LayerStyleProperties.html
- Arc's View > Show Toolbar and its Command-Shift-D shortcut: https://resources.arc.net/hc/en-us/articles/25625458052247-How-Do-You-View-the-Full-URL-at-the-Top-of-the-Page-in-Arc-for-Desktop and https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes
- Arc's sidebar URL bar shows the site rather than the full address, which is why Arc documents a way to see the full URL (same help article).
- Arc in full screen keeps its border around the page until the sidebar is hidden as well: https://www.alexandergoller.com/journal/14870/arc-browser
- CEF's `CefBrowserHost::ExitFullscreen` (with Alloy style the app calls it on Escape and when leaving window full screen) and `CefDisplayHandler::OnFullscreenModeChange`.
- An Arc style window reference (tinted frame, the page inset about 8 px on three sides with rounded corners): https://deviceshots.com/browsers/arc/
