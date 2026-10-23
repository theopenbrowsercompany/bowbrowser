# Favorites

## Summary

Favorites are the few sites a person reaches for all day, kept as a grid of icons at the top of the sidebar.
They belong to a profile, so every Space that uses that profile shows the same Favorites.

## Behavior

- The Favorites area sits above the pinned tabs and shows each Favorite of the profile the Space on screen uses as a tile in a grid, four to a row, filled left to right and top to bottom.
- A tile shows its site's icon when the window has one for it (the icon the tab showed when it was dragged onto the grid); otherwise it shows the first letter of the Favorite's name on a colored square.
  Hovering a tile shows the Favorite's name.
- The grid is exactly as tall as its rows of tiles, and grows or shrinks a row at a time as Favorites come and go.
  With no Favorites it shrinks to a thin strip that still takes a dropped tab.
- Dragging a tab from the pinned or today zone onto the grid makes it a Favorite at the place under the pointer.
  The tab moves rather than being copied: it leaves its zone and keeps the address it was saved with.
- Dragging a tile within the grid reorders the Favorites.
- Dragging a tile out to the pinned or today zone moves it there as a tab, keeping its saved address; it is no longer a Favorite.
- Folders and split views cannot be dropped onto the grid, and a tab inside a split view cannot leave it that way.
- A profile holds at most twelve Favorites; a thirteenth tab dropped on the grid is refused.
- Clicking a tile opens the Favorite's saved page as a new tab in today of the Space on screen and shows it.
  Clicking it again while that tab is still in the Space shows that tab instead of opening another, and the tile is highlighted while its tab is the one shown.
- Right-clicking a tile shows "Remove from Favorites", which takes it out of the grid and keeps it as a tab at the top of today, so nothing is lost.

## Edge cases

- Switching to a Space of another profile shows that profile's Favorites; Spaces of the same profile show the same grid.
- A Favorite whose saved address is empty shows its letter tile and does nothing when clicked.
- Favorites are never archived or closed by auto-archiving.
- Favorites are saved with the sidebar, so they come back in order after a relaunch.

## Acceptance checks

1. Open tabs A, B and C, drag A then B onto the grid: the grid shows A then B with their icons in one row, and today lists only C.
2. Drag B before A: the grid shows B then A.
3. Click B: a tab showing B opens in today and is shown, and B's tile is highlighted; select C, click B again: the same tab is shown and no other opens.
4. Drag A out to the pinned zone: the grid shows B alone and A is the first pinned tab.
5. Right-click B and choose "Remove from Favorites": the grid is empty and B is the first tab in today.

## Out of scope

- Loading a Favorite in place as its own tab shared by every Space, peeking at links that leave a Favorite's site, and a keyboard shortcut or command to favorite a tab.
- Moving a tab to Favorites from its context menu ("Move To").
- Keeping site icons for Favorites across relaunches and windows; until then a Favorite shows its letter tile after a relaunch.
- The sidebar's zones and drags between pinned and today, covered in `sidebar.md`; how Favorites are saved, in `sidebar-store.md`.
