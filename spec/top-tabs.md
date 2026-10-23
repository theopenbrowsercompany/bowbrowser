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
  The tab strip row is 46 high with the window buttons at its leading edge, 14 in; it is reserved for the tab pills, which a later slice adds.
  The toolbar row is 44 high with 14 padding on each side and 14 between items: back, forward and reload (17 point symbols in the Soft color), the URL field (32 high, flexible width, radius 10, Active fill, showing the shown tab's site as the sidebar's field does), and the Space dots (14 point dots, the Space on screen with a 2 point ring).
- The page card keeps its 8 point inset on its leading, bottom and trailing sides, its radius 10 and its shadow; its top sits under the toolbar row.
- Cmd+L, the command bar, Copy Current URL and Space switching work in both layouts.
  A click on a dot shows that Space; the dots show the Spaces and the one on screen.
- View > Hide Toolbar hides the toolbar row in this layout too, and the card rises under the strip with its 8 point inset.
- Full screen has no title bar, so the window buttons are left to the system there.

## Not yet

- The tab strip itself (tab pills, selection, close and +) and pinned tabs or Favorites in it.
- The Downloads button and the sidebar's other footer items have no place in this layout yet.

## Checked by

`make e2e E2E=toptabs`: the default, the setting and its saved value, the rows' measurements and items, the URL field, the Space dots, Cmd+L, a window opened while on, and the sidebar restored.
