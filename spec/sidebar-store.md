# Saving the sidebar

## Summary

The sidebar (Spaces, Favorites, pinned and unpinned tabs, folders and split views) is the person's workspace, so its structure survives quitting, crashes and relaunching exactly as they left it.
Bow keeps it in one file of its own, separate from the engine's session data.

## Behavior

- Every change to the sidebar (adding, moving, renaming or closing a tab, folder, split or Space) is saved to the sidebar file right after it happens.
- Quitting saves anything not yet written, so the next launch shows the same Spaces, sections, folders and tabs in the same order.
- A group of related changes (for example dragging a folder into another Space) is saved all together or not at all; a half-applied change never reaches the file.
- A tab remembers the address and title it was saved with.
  Browsing inside a tab does not silently change what it returns to: the saved address changes only when Bow means it to (pinning a tab, choosing to change its saved address, or recording an unpinned tab's page).
- On launch only the tab that was selected loads its page right away.
  Every other tab appears in the sidebar with its saved title and loads when it is selected.
- Folders nest to any depth and keep whether they were open or closed.
  Split views keep their tabs and their orientation.
- A folder holds tabs, split views and other folders in the order the person set.
  It can be created (empty), renamed, opened or closed, and moved with everything inside it to another folder, another position or another Space's section.
  A folder cannot be moved into itself or into anything inside it; Bow refuses such a move and changes nothing.
- Deleting a folder either deletes everything inside it, or keeps its contents: the tabs, split views and folders inside take the folder's place under its parent, in their order, and sub-folders keep their own contents.
- Empty folders are kept, and so is a closed folder's contents: closing a folder hides its items but never changes them.
- Collapse all closes every folder of the current Space at any depth, in the pinned section and in the tabs section, as one saved change.
  The selected tab always stays visible: the folders above it stay open, and any of them that was closed is opened again.
  When the selected tab is in another Space or in Favorites, nothing needs to stay open and every folder closes.
  Other Spaces are not touched, tabs and their order do not change, and the closed state is saved like any other open or closed state.
  Collapsing when everything is already closed changes nothing.
  Expand all opens every folder of the current Space again.
- A closed folder hides everything inside it, however deep; the rows the sidebar shows are the sections' items in order, without the contents of closed folders.
  A split view cannot be closed: its tabs are shown whenever the split itself is.
- Favorites are the row of icons at the top of the sidebar.
  There is one Favorites row per profile, and every Space of that profile shows the same row; a Space on another profile shows that profile's own row, which starts empty.
  Until the person can choose profiles, every Space uses the default profile and so shares one row.
- A Favorite is a tab that remembers the address and title it was saved with, like a pinned tab.
  Browsing inside it does not change what it returns to.
- Favorites hold tabs only, in the order the person set; folders and split views cannot go into Favorites.
- A Favorite can be added as a new address, or an open tab can be made a Favorite; the tab then leaves its section and returns to the page it was on when it was made a Favorite.
  Favorites can be reordered, and the new order is where the Favorite ends up.
- Removing a Favorite does not close it: it becomes an ordinary tab at the top of the Space on screen's tabs (or its pinned tabs), with the address it was saved with.
  A Favorite can also be deleted for good.
- Archiving never touches Favorites.
- The sidebar file lives in Bow's Application Support folder (`~/Library/Application Support/Bow/Sidebar.json`).
  Browsing history and site icons are not stored in it.

### Pinned tabs

- Pinned tabs are the sites kept open all the time.
  They sit in their own section at the top of a Space, above its other tabs, and each Space has its own pinned tabs.
- Pinning a tab moves it, alone, to the end of its Space's pinned section (or to the position it was dropped at), even when it came out of a folder.
  A Favorites tab pins into the Space on screen.
  A tab inside a split view cannot be pinned on its own.
- Pinning records the page the tab is showing as its saved address and title.
  The saved address and title are stored on the tab, apart from the page it shows right now, and that page is never saved as the address.
- Unpinning moves the tab to the top of its Space's tabs section (or to the position it was dropped at).
  The page the tab is showing then becomes its saved page, so the tab stays on it after a relaunch.
- Pinned tabs can be reordered within the pinned section and within a folder in it.
- When a pinned tab shows a different page than its saved address, the sidebar offers "Back to pinned URL", which loads the saved address again and changes nothing in the sidebar.
  A page counts as different unless its address differs only in letter case of the site name, a default port, an empty path versus "/", or a `#fragment`; a different path or query is a different page.
  A tab with no page loaded has not navigated away.
- "Replace pinned URL with current" makes the page the tab is showing its new saved address and title.
  It is an explicit choice: browsing, going back to the pinned URL, closing and relaunching never change the saved address.
- Closing a pinned tab unloads its page but keeps the tab in the sidebar with its saved address and title.
  Selecting it loads its saved address, not the page it was last showing.
  Closing any other tab removes it from the sidebar.

## Edge cases

- First launch, or the file is missing: Bow starts with one empty Space and empty Favorites, and writes the file once there is something to save.
- The file cannot be read at all (cut short, not Bow's format, or written by a newer Bow): Bow starts with one empty Space and moves the old file aside as `Sidebar.unreadable-<date>-<time>.json` in the same folder, untouched.
  A later unreadable file gets its own name and never replaces an earlier one.
  If the file cannot be moved aside, Bow does not write over it.
- The file was written by an older Bow: it is upgraded on launch, and a copy of the original is kept beside it as `Sidebar.version-<old version>.json`.
- Bow crashes or the Mac loses power while saving: the file holds either the sidebar from before the change or the one after it, never a mix.
  Leftover temporary files from an interrupted save are removed at the next launch.
- Saving fails (for example the disk is full or the folder is read-only): the change stays visible, Bow tries again with the next change and on quit, and the file keeps its previous contents meanwhile.
- The file's structure disagrees with itself (a tab whose folder no longer lists it, a folder listing a tab that is gone, items pointing at each other in a loop, a Space whose section is missing): Bow repairs it on launch.
  Tabs, folders and splits that have no valid place are never deleted; they are collected in a folder named "Recently recovered", keeping their contents.
  That folder is created at the top of the current Space's pinned section, and if it already exists wherever the person put it, recovered items are added to its end.
- A Space is created on a profile that has no Favorites row yet: the row is created with it.
  Deleting the last Space of a profile keeps that profile's Favorites.
- Adding a Favorite to a profile Bow does not know is refused and changes nothing.
- A selected Favorite stays selected when switching to a Space of the same profile; switching to a Space of another profile selects that Space's own tab instead.
  Selecting a Favorite from somewhere else shows a Space of its profile when the Space on screen is on another profile.
- A sidebar saved before Favorites were per profile opens with its one Favorites row on the default profile, and a copy of the old file is kept as `Sidebar.version-1.json`.
- A Favorites row that is missing is created empty on launch for the default profile and for every profile a Space uses.
  A folder or split view found inside Favorites goes to "Recently recovered".
- A single entry in the file cannot be read (for example one tab saved in a form this Bow does not know): only that entry is left out, the rest of the sidebar opens, and anything that was inside it goes to "Recently recovered".
- Whenever launch had to repair the file, a copy of it as it was is kept beside it as `Sidebar.repaired-<date>-<time>.json` before Bow saves over it.
- A Space's pinned and unpinned sections are removed only together with the Space, and the last Space cannot be deleted: there is always at least one Space.
- Hundreds of tabs: only the selected one loads at launch, so startup stays quick.
- Pinning a tab that is already pinned, or unpinning one that is not, changes nothing; in particular pinning again never overwrites the saved address.
- A pinned tab with no usable saved address has nothing to go back to: it never shows "Back to pinned URL" and loads nothing when selected.

## Acceptance checks

1. Make three folders (one inside another), pin some tabs, add a split view and a second Space, then quit and relaunch: everything appears in the same place and order.
2. Select a tab in a folder, quit and relaunch: only that tab loads; selecting another tab loads it then.
3. Pin a tab, browse to another page inside it, quit and relaunch: the pinned tab returns to the address it was pinned on.
4. Quit, replace the sidebar file's contents with random text, relaunch: Bow opens with one empty Space and the folder holds `Sidebar.unreadable-<date>-<time>.json` with the random text unchanged.
5. Quit, delete the sidebar file, relaunch: Bow opens with one empty Space and no error.
6. Quit, edit the file so a folder no longer lists one of its tabs while the tab still names the folder, relaunch: the tab is back in that folder.
7. Quit, edit the file so a tab names a folder that does not exist and no folder lists it, relaunch: the tab is in "Recently recovered" at the top of the pinned section.
8. Run `make e2e`: the `store.roundtrip` test saves a sidebar of twelve items, relaunches, and prints `PASS store.roundtrip: items=12 after_relaunch=12`.
9. Make folders client, project and phase, each inside the previous one, with a tab A in phase, plus an empty folder, then close "project": quit and relaunch, and the tree is client/project/phase/[A], "project" is still closed and the empty folder is still there.
10. Delete "project" keeping its contents: "phase" and its tab are now directly inside "client", where "project" was.
    Delete "client" with its contents: everything inside it is gone.
11. Try to drag "client" into "phase": Bow refuses and the tree is unchanged.
12. Pin tab A while it shows page A, browse inside it to page B: "Back to pinned URL" shows. Choose it: the tab shows page A and the button is gone.
13. Browse the pinned tab to page B and choose "Replace pinned URL with current": the saved address is B and the button is gone. Quit and relaunch: the tab returns to B.
14. Close a pinned tab that browsed away from its saved page, then select it: it loads the saved address.
15. Drag a pinned tab above another one, then drag it to the tabs section: the order changes, then it leaves the pinned section and sits on top of the tabs.
16. Run `make e2e`: `pinned.reset` prints `PASS pinned.reset: saved=A navigated=B reset=A`.
17. Add two Favorites A and B, then make an open tab C a Favorite at the front: the row reads C, A, B and C returns to the page it was on when it was made a Favorite.
    Move A to the end: the row reads C, B, A.
    Remove B: it is a tab at the top of the Space on screen and the row reads C, A.
    Quit and relaunch: the row and the saved addresses are the same.
18. With two Spaces on the default profile, both show the row C, A.
    Create a Space on another profile: its row is empty, and adding a Favorite there leaves the other row unchanged.
19. Try to make a folder or a split view a Favorite: Bow refuses and nothing changes.
20. Make folders client, project and phase (each inside the previous one) with a tab A in phase, plus folders reading and later holding tabs, and select A. Choose Collapse all: reading and later close, client, project and phase stay open and A is visible.
    Quit and relaunch: the same folders are closed and open.
21. Select a tab in "later", close "later" by hand, then choose Collapse all: "later" opens again so the selected tab is visible, and every other folder closes.
22. With a second Space that has its own folders, choose Collapse all in the first Space: the second Space's folders keep their state.
    Select a Favorite, then choose Collapse all: every folder of the current Space closes.
23. Run `make e2e`: `collapse` prints `PASS collapse: collapsed=3 visible=A`.

## Out of scope

- How tabs, folders and Spaces look and how they are dragged in the sidebar.
- How the Favorites icon grid looks, and dragging into, within and out of it.
- Choosing a profile for a Space, and confirming a move between profiles.
- Archiving closed tabs and the archive's own file.
- Importing an Arc sidebar.
- Syncing the sidebar between devices.
- Restoring a tab's back and forward history.
