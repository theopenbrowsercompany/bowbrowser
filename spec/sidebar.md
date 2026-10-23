# Sidebar sections

## Summary

The sidebar shows a Space as three zones, top to bottom: Favorites, pinned tabs and today's tabs.
Pinned tabs are the sites a person keeps; today's tabs are the ones they opened along the way, so new tabs land there and only they are ever archived.

## Behavior

- The sidebar lists, top to bottom: the Favorites area of the profile the Space on screen uses, that Space's pinned tabs, a divider line, and its today tabs.
- The divider is always shown, also when the pinned or today zone is empty, so there is always somewhere to drop a tab.
- A New Tab row ends the list, after the last of today's tabs (also after a folder, open or closed), and in a Space with only pinned tabs or none at all.
  It is drawn like a tab row (34 high, a plus symbol and "New tab" in the Soft color, the UI font, the hover tint of other rows) but is not a tab: it is never selected or counted, a tab cannot be dropped on it, and a tab dropped below it goes to the end of today.
  Clicking it opens the command bar for a new tab, as Command-T does (Arc's help center says its sidebar plus button opens the command bar; where it sits follows the mockup, as Arc's pages do not settle that).
- Every way of opening a tab (the New Tab row, Command-T, a link from another app, a page opening a tab) adds it to today: right after the active tab when that tab is in today, otherwise at the end.
- Folders in the pinned or today zone show as rows with a disclosure triangle and their contents indented below them.
  Opening or closing a folder with its triangle is saved, and a closed folder hides its contents.
- Split views show as a row with their tabs below it; they are always open.
- Dragging a row moves it within its zone, into a folder, or across the divider:
  - a today tab dropped among the pinned tabs is pinned there, and the page it shows becomes the address it returns to;
  - a pinned tab dropped among today's tabs is unpinned there, and keeps the page it shows;
  - a tab dropped on another tab lands just above it, one dropped on the divider lands at the top of today, and one dropped on a folder lands at its end;
  - a folder or split moves with everything inside it.
- Dropping between two rows where the gap could mean more than one level (below a folder's last child) lands on the level the pointer's x picks, stepping 22 points per level as folder rows do: at a folder's own x the drop goes after the folder, leaving it, and at its children's x it stays inside; the drop gap opens at that level.
  Below an open folder the gap is its first slot, and below a closed folder the drop goes after it.
- A drag never changes the active tab.
- A row's hover tint and close button clear when a scroll moves the row away from a still pointer.
- Some drags are refused, and the sidebar shows no drop gap for them: a row dropped into itself, a tab taken alone out of a split view or dropped into one, and anything dragged into or out of Favorites other than what `spec/favorites.md` allows.
- Right-clicking a tab row shows its menu; for now that menu has Close Tab, which closes the tab as its close button does.
- Folder actions (New Folder, Rename Folder, the delete items, renaming by double-clicking a folder's row) are in `folders.md`.
- Closing the selected pinned tab unloads it and selects the next tab in sidebar order.
- A tab row's menu also has Pin Tab (a today tab) or Unpin Tab (a pinned tab). Pinning saves the page the tab shows as the page it returns to; unpinning moves the tab to the top of today and keeps the page it shows.
- A pinned tab whose page has left its saved address shows a small Soft arrow button before its close button, "Back to Pinned URL", which loads the saved address in that tab. It is hidden while the page is on its saved address or unloaded.
- The same tab's menu then has Replace Pinned URL with Current, the only way the saved address changes after pinning; browsing never changes it.
- The bottom of the sidebar is a footer slot for controls such as the archive button, empty for now; empty, it takes no room.

### Extension points

The sidebar is built so later features each add one file plus one line in a list, in `App/UI/Sidebar/`:

- Sections: a type conforming to `SidebarSection`, listed in `SidebarSections.all` (`SidebarSectionList.swift`) in top to bottom order.
  A section has a header row (a thin spacer, or a view such as the divider or the Favorites grid) and the items of one container of the Space on screen.
  A header view is made once per window and handed the sidebar's fresh content each time the sidebar updates, so a header such as a Space switcher always matches the Space on screen; its height may follow the content too.
- Accessories: a class conforming to `SidebarAccessory`, listed in `SidebarAccessories.all` (`SidebarAccessoryList.swift`), placed in the top slot (between the top row and the list) or the footer slot (along the bottom), in list order, and handed fresh content on every update.
- Tab row accessories: a type conforming to `SidebarRowAccessory`, listed in `SidebarRowAccessories.all` (`SidebarAccessoryList.swift`), giving a view shown before a tab row's close button (such as "Back to pinned URL"); it is asked again each time the row is drawn and whenever the sidebar updates, and the first provider with a view wins.
- Context menu items: a type conforming to `SidebarMenuItems`, listed in `SidebarMenus.all` (`SidebarMenuList.swift`), naming the item kinds it serves (tab, folder, split, Favorite, or a section's header by zone, given the container that section lists).
  Each provider's items appear in list order, separated from the next provider's.
- Drop rules: a type conforming to `SidebarDropValidator`, listed in `SidebarDropValidators.all` (`SidebarDropRuleList.swift`).
  A drop goes through when no rule refuses it; the store's own rules (what may hold what, repairing split views) still apply when it is made.
  The rule for drags into and out of Favorites lives alone in `FavoritesDropRule.swift`.
- Swipes: a `SidebarSwipeHandler` gets each sideways two-finger trackpad swipe on the list, with its phase, the distance moved so far and the action context; without one, every scroll goes to the list.
  An accessory offers it (the first accessory with one wins), or code holding the sidebar sets it once the window has opened; the sidebar keeps it.
  The list does not follow the fingers yet: it slides once the handler acts.
  The sidebar's slide helper swaps the list's content with a slide to the left or right, and skips the slide when Reduce Motion is on.
- Actions: the context every menu item, drop, accessory, header and swipe handler gets can read the sidebar, select, close and load a tab at an address (a tab whose page has not loaded is shown and loaded, as selecting it does), and change the store.
  - It gives a tab's site icon when one has loaded; a Favorite has none until Favorites load in place.
  - Opening a Favorite loads its saved address in a new tab in today, which is shown, for now.
  - Beginning a rename makes a folder's or split view's name editable in its row: Return or leaving the field saves a new name, and Escape or an empty name keeps the old one.
  - Deleting a folder with its tabs moves the active tab out of the folder first, closes the folder's loaded tabs as their close buttons do (a page that asks to stay keeps the folder), then removes the folder and everything in it.
  - Asking to confirm shows a sheet on the window with the action's button and Cancel, and runs the action only when its button is chosen.
  - Sliding the list runs a change (switching Spaces) inside the slide helper, so the old content leaves to one side as the new arrives.
  - Headers and accessories only update their views when the sidebar updates them; an action they take there is shown on the next turn of the run loop, not in the middle of the update.

## Edge cases

- A Space with no pinned tabs shows the divider right under the Favorites area; one with no today tabs shows it at the bottom of the list.
- Favorites show as an icon grid in the Favorites area, not as rows (`spec/favorites.md`).
- A drop the store refuses (for example a change that would break the sidebar's rules) changes nothing and is reported in the log.
- A drop where the item already is changes nothing and saves nothing.
- After a relaunch every tab is back in its zone and folder, in the same order, with folders open or closed as they were.

## Acceptance checks

1. Run `make e2e`: `PASS zones: new_tab=today` shows a tab opened through the New Tab row's command bar landing in today, beside the window's first tab.
2. Run `make e2e`: `PASS zones.pin: A=pinned tabs=[A,B] active=B` shows tab A dragged into the pinned zone above B, with B still active.
3. Run `make e2e`: `PASS zones.divider: favorites | pinned | A | divider | today | B` shows the outline's rows with the divider between the pinned and today tabs.
4. Run `make e2e`: `PASS zones.unpin: A=today tabs=[B,A] active=B` shows A dragged back below B into today, unpinned.
5. Run `make e2e`: `PASS zones.drop-divider: favorites | pinned | divider | today | A | B` shows A dropped on the divider row landing at the top of today.
6. Run `make e2e`: `PASS zones.drop-tab: favorites | pinned | divider | today | B | A` shows B dropped on A's row landing above it.
7. Run `make e2e`: `PASS newtab`, `PASS newtab.look`, `PASS newtab.bar`, `PASS newtab.dismiss`, `PASS newtab.open`, `PASS newtab.not-a-tab` and `PASS newtab.places` show the New Tab row last in the list and styled as above, opening the command bar with no tab, closing on Escape with no tab, opening a tab after the active one when an address is chosen, never selected, refusing a drop on it, and ending the list in a Space with only pinned tabs and in an empty one.
8. By hand: drag a today tab above the divider; it moves into the pinned tabs; close it and it stays in the sidebar, unloaded; select it and it loads the page it was pinned on.

9. Run `make e2e`: `PASS pinned.menu`, `PASS pinned.reset: saved=A navigated=B reset=A`, `PASS pinned.replace`, `PASS pinned.unpin` and `PASS pinned.close-next` show the pin menu items, the back button resetting the page, the explicit replace, unpinning and the next tab becoming active when the selected pinned tab closes.

## Out of scope

- The Space switcher, collapse all and the archive popover; each plugs into the extension points above.
- Saving the sidebar and the store's rules, covered in `sidebar-store.md`; tab behavior in `tabs.md`.
