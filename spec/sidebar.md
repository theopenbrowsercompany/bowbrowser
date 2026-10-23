# Sidebar sections

## Summary

The sidebar shows a Space as three zones, top to bottom: Favorites, pinned tabs and today's tabs.
Pinned tabs are the sites a person keeps; today's tabs are the ones they opened along the way, so new tabs land there and only they are ever archived.

## Behavior

- The sidebar lists, top to bottom: the Favorites area of the profile the Space on screen uses, that Space's pinned tabs, a divider line, and its today tabs.
- The divider is always shown, also when the pinned or today zone is empty, so there is always somewhere to drop a tab.
- Every way of opening a tab (the New Tab button, Command-T, a link from another app, a page opening a tab) adds it to today: right after the active tab when that tab is in today, otherwise at the end.
- Folders in the pinned or today zone show as rows with a disclosure triangle and their contents indented below them.
  Opening or closing a folder with its triangle is saved, and a closed folder hides its contents.
- Split views show as a row with their tabs below it; they are always open.
- Dragging a row moves it within its zone, into a folder, or across the divider:
  - a today tab dropped among the pinned tabs is pinned there, and the page it shows becomes the address it returns to;
  - a pinned tab dropped among today's tabs is unpinned there, and keeps the page it shows;
  - a tab dropped on another tab lands just above it, one dropped on the divider lands at the top of today, and one dropped on a folder lands at its end;
  - a folder or split moves with everything inside it.
- A drag never changes the active tab.
- Some drags are refused, and the sidebar shows no drop gap for them: a row dropped into itself, a tab taken alone out of a split view or dropped into one, and anything dragged into or out of Favorites (the Favorites grid brings its own drags).
- Right-clicking a tab row shows its menu; for now that menu has Close Tab, which closes the tab as its close button does.
- Closing the selected pinned tab unloads it and selects the next tab in sidebar order.
- The bottom of the sidebar keeps room for footer controls (the archive), empty for now.

### Extension points

The sidebar is built so later features each add one file plus one line in a list, in `App/UI/Sidebar/`:

- Sections: a type conforming to `SidebarSection`, listed in `SidebarSections.all` in top to bottom order.
  A section has a header row (a thin spacer, or a view such as the divider or the Favorites grid) and the items of one container of the Space on screen.
- Context menu items: a type conforming to `SidebarMenuItems`, listed in `SidebarMenus.all`, naming the item kinds it serves (tab, folder, split, Favorite).
  Each provider's items appear in list order, separated from the next provider's.
- Drop rules: a type conforming to `SidebarDropValidator`, listed in `SidebarDropValidators.all`.
  A drop goes through when no rule refuses it; the store's own rules (what may hold what, repairing split views) still apply when it is made.

## Edge cases

- A Space with no pinned tabs shows the divider right under the Favorites area; one with no today tabs shows it at the bottom of the list.
- A Favorite shows as a plain row with its saved title until the Favorites grid exists; clicking it does nothing yet.
- A drop the store refuses (for example a change that would break the sidebar's rules) changes nothing and is reported in the log.
- After a relaunch every tab is back in its zone and folder, in the same order, with folders open or closed as they were.

## Acceptance checks

1. Run `make e2e`: `PASS zones: new_tab=today` shows a tab opened with the New Tab button landing in today, beside the window's first tab.
2. Run `make e2e`: `PASS zones.pin: A=pinned tabs=[A,B] active=B` shows tab A dragged into the pinned zone above B, with B still active.
3. Run `make e2e`: `PASS zones.divider: favorites | pinned | A | divider | today | B` shows the outline's rows with the divider between the pinned and today tabs.
4. Run `make e2e`: `PASS zones.unpin: A=today tabs=[B,A] active=B` shows A dragged back below B into today, unpinned.
5. By hand: drag a today tab above the divider; it moves into the pinned tabs; close it and it stays in the sidebar, unloaded; select it and it loads the page it was pinned on.

## Out of scope

- The Favorites icon grid, the Space switcher, pinned tab actions (back to pinned URL, replace pinned URL), folder actions, collapse all and the archive popover; each plugs into the extension points above.
- Saving the sidebar and the store's rules, covered in `sidebar-store.md`; tab behavior in `tabs.md`.
