# Favorites

## Summary

Favorites are the few sites a person reaches for all day, kept as a grid of icons at the top of the sidebar.
They belong to a profile, so every Space that uses that profile shows the same Favorites.
Each Favorite is its own tab: it opens in place, and there is never a copy of it among the Space's tabs.

## Behavior

- The Favorites area sits above the pinned tabs and shows each Favorite of the profile the Space on screen uses as a tile in a grid, four to a row, filled left to right and top to bottom.
- A tile shows its site's icon when the window has one for it (its page's icon, or the icon the tab showed when it was dragged onto the grid); otherwise it shows the first letter of the Favorite's name on a colored square.
  Hovering a tile shows the Favorite's name.
- The grid is exactly as tall as its rows of tiles, and grows or shrinks a row at a time as Favorites come and go.
  With no Favorites it shrinks to a thin strip that still takes a dropped tab.
- Dragging a tab from the pinned or today zone onto the grid makes it a Favorite at the place under the pointer.
  The tab moves rather than being copied: it leaves its zone, keeps the address it was saved with, and keeps its open page as the Favorite's page.
  Dragging the tab on screen keeps it on screen and active, so the address bar, Back and Forward, Find and Close Tab still act on it.
- Dragging a tile within the grid reorders the Favorites.
- Dragging a tile out to the pinned or today zone moves it there as a tab, keeping its saved address; it is no longer a Favorite.
- Folders and split views cannot be dropped onto the grid, and a tab inside a split view cannot leave it that way.
- A profile holds at most twelve Favorites; a thirteenth tab dropped on the grid is refused.
- Clicking a tile shows that Favorite in place as the active tab: its own page when it has one open, else its saved address loads as its page.
  No tab opens in today, and the tile is highlighted while its Favorite is the tab shown (no row in the outline is highlighted then).
- A Favorite keeps the address it was saved with while its page navigates elsewhere, as a pinned tab does.
- Close Tab (Cmd+W) on a Favorite closes its page but keeps it in the grid; the Space's first tab is shown instead, or, when the Space has no tabs, the Favorite stays active with no page loaded.
  Clicking its tile again loads its saved address, so a Favorite that wandered off returns to where it was saved.
- Right-clicking a tile shows "Remove from Favorites", which takes it out of the grid and keeps it as a tab at the top of today with its open page, so nothing is lost or duplicated.

## Edge cases

- Switching to a Space of another profile shows that profile's Favorites; Spaces of the same profile show the same grid, and a Favorite shown stays shown across a switch to another Space of its profile.
- An empty Space never loads a Favorite by itself: it shows its empty state until the person clicks one.
  Its Favorites stay listed and work as in any other Space: clicking a tile, or its quick link on the start screen, shows it in place, and the start screen's quick links show the icons the window has for them.
- A Favorite whose saved address is empty shows its letter tile and does nothing when clicked.
- Favorites are never archived or closed by auto-archiving.
- Favorites are saved with the sidebar, so they come back in order after a relaunch.

## Acceptance checks

1. Open tabs A, B and C, drag A then B onto the grid: the grid shows A then B with their icons in one row, and today lists only C.
2. Drag B before A: the grid shows B then A.
3. Click B: B's own page is shown in place, B's tile is highlighted, today still lists only C and nothing new loads; select C, click B again: the same page is shown.
4. Drag A out to the pinned zone: the grid shows B alone and A is the first pinned tab.
5. Right-click B and choose "Remove from Favorites": the grid is empty and B is the first tab in today, with its page still open.
6. With tabs A and D open and D shown, drag D onto the grid: D stays shown with its tile highlighted; load another page in it from the address bar and Back turns on.
7. Choose Close Tab: D's page closes, D stays in the grid and A is shown; click D: it loads its saved address in place, not the page it navigated to.
8. With A, carrying its icon, in the grid, switch to a new empty Space of the same profile and add Favorite S that has never loaded: the start screen's quick links show A's icon and S's letter.
9. Click S's tile in the sidebar: S loads its saved address in place and the start screen gives way; switch to the first Space and back, then click A's tile: A's own page shows.

## Out of scope

- Peeking at links that leave a Favorite's site, a "Back to saved address" control on a Favorite's tile, and a keyboard shortcut or command to favorite a tab.
- Moving a tab to Favorites from its context menu ("Move To").
- Keeping site icons for Favorites across relaunches and windows; until then a Favorite shows its letter tile after a relaunch.
- The sidebar's zones and drags between pinned and today, covered in `sidebar.md`; how Favorites are saved, in `sidebar-store.md`.
