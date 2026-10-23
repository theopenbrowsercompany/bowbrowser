# Top tabs layout

An optional layout for people who prefer horizontal tabs.
Arc itself has only the sidebar, so this is an opt-in setting; the sidebar layout stays the default.
The measurements come from the maintainer's own mockup 4, not from Arc.

## Behavior

- View > Use Top Tabs switches every open window between the sidebar layout and the top tabs layout.
  The item shows a check while the top tabs layout is on, and has no shortcut.
- The choice is one app setting, saved across launches.
  A window opened while it is on starts in the top tabs layout.
- In the top tabs layout the sidebar is out of the window.
  Switching back brings the same sidebar back as it was: its Space, tabs, folders and scroll position.
- Above the page card sit two rows.
  The tab strip row is 46 high with the window buttons at its leading edge, 14 in, and holds the tab pills (below).
  The toolbar row is 44 high with 14 padding on each side and 14 between items: back, forward and reload (17 point symbols in the Soft color), the URL field (32 high, flexible width, radius 10, Active fill, showing the shown tab's site as the sidebar's field does), and the Space dots (14 point dots, the Space on screen with a 2 point ring).
- The page card keeps its 8 point inset on its leading, bottom and trailing sides, its radius 10 and its shadow; its top sits under the toolbar row.
- Cmd+L, the command bar, Copy Current URL and Space switching work in both layouts.
  A click on a dot shows that Space; the dots show the Spaces and the one on screen.
- View > Hide Toolbar hides the toolbar row in this layout too, and the card rises under the strip with its 8 point inset.
- The strip shows the Space on screen's today tabs only (folders' tabs included, no pinned tabs or Favorites), one pill each, after the window buttons with a 10 point gap.
  A pill is 190 by 32, radius 10, 8 apart, 12 padding inside: the site icon (15 points, a globe without one), then the title at 13 points in one line, truncated.
  The shown tab's pill has the Active fill, a bold title and the soft lift shadow (0 1 3 at 14 percent Night); the others have no fill, and a hovered one takes the Pin tint.
  When the window shows a pinned tab or Favorite, no pill is lifted.
- A click on a pill shows its tab.
  A close button shows on the shown pill and on a hovered one and closes the tab as the sidebar's close button does; a middle click closes too.
- The + button after the last pill (17 point plus in the Soft color, in a 32 point square) opens the command bar like Cmd+T.
  It follows the last pill, and stays at the strip's end once the pills fill the row.
- Pills shrink evenly together when they do not fit, as Chrome's tabs do, down to 96 wide.
  Below that they keep 96 and the row scrolls (trackpad, or a mouse wheel's vertical turns), keeping the shown tab's pill in view.
- The strip follows the sidebar store: switching Space shows that Space's tabs, and a tab opening, closing, loading or changing its title or icon updates its pill.
- Full screen has no title bar, so the window buttons are left to the system there.

## Not yet

- Pinned tabs or Favorites in the strip, dragging pills to reorder, a loading spinner on a pill, a pill context menu.
- The Downloads button and the sidebar's other footer items have no place in this layout yet.

## Checked by

`make e2e E2E=toptabs`: the default, the setting and its saved value, the rows' measurements and items, the URL field, the Space dots, Cmd+L, a window opened while on, and the sidebar restored.
`make e2e E2E=toptabs.strip`: the pills' sizes and place, the lifted pill, +, selecting, close (shown and hovered), shrinking, scrolling and revealing, and switching Spaces.
