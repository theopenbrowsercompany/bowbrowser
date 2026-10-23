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
- The sidebar file lives in Bow's Application Support folder (`~/Library/Application Support/Bow/Sidebar.json`).
  Browsing history and site icons are not stored in it.

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
- A single entry in the file cannot be read (for example one tab saved in a form this Bow does not know): only that entry is left out, the rest of the sidebar opens, and anything that was inside it goes to "Recently recovered".
- Whenever launch had to repair the file, a copy of it as it was is kept beside it as `Sidebar.repaired-<date>-<time>.json` before Bow saves over it.
- A Space's pinned and unpinned sections are removed only together with the Space, and the last Space cannot be deleted: there is always at least one Space.
- Hundreds of tabs: only the selected one loads at launch, so startup stays quick.

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

## Out of scope

- How tabs, folders and Spaces look and how they are dragged in the sidebar.
- Archiving closed tabs and the archive's own file.
- Importing an Arc sidebar.
- Syncing the sidebar between devices.
- Restoring a tab's back and forward history.
