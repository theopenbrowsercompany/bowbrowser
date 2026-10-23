# Folders

## Summary

Folders group tabs in a Space's sidebar, nested as deep as a person likes, so a client can hold its projects and a project its phases.
They are made, renamed and deleted from the sidebar's context menus, and they keep their contents and their open or closed state across relaunches.

## Behavior

- Right-clicking the pinned section's header row offers New Folder, which adds an empty folder at the end of the pinned tabs.
- Right-clicking a folder offers New Folder, which adds an empty folder at the end of that folder, opening the folder first when it is closed.
- A new folder is named "New Folder" and starts with that name selected in its row, ready to type over.
- Right-clicking a folder offers Rename Folder, and double-clicking a folder's row does the same: its name becomes editable in place.
  - Return or clicking elsewhere saves the new name; Escape, or an empty name, keeps the old one.
- A folder that holds anything offers two ways to delete it:
  - Delete Folder and Tabs asks first, in a sheet naming the folder and how many tabs it holds; Delete removes the folder and everything in it, and Cancel changes nothing.
    Open tabs in it close as their close buttons would close them, and when the active tab was inside, the nearest tab outside the folder becomes active first.
  - Delete Folder, Keep Tabs removes only the folder: what it held moves up into the folder's place in its parent, in the same order.
- An empty folder offers a single Delete Folder, which asks nothing.
- A folder's disclosure triangle opens or closes it; a closed folder hides its contents, and each folder remembers its own state.
- Dragging works at every level: a tab or folder can be dropped into any folder, a folder moves with everything inside it, and a folder dragged from today into the pinned tabs (or into a pinned folder) is pinned with its contents.
  The drag rules themselves are in `sidebar.md`.

## Edge cases

- An empty folder is kept and listed, also after a relaunch.
- Folders nest without a depth limit; a folder cannot be dropped inside itself or its own subfolders.
- After a relaunch every folder is back in place with its name, its contents in order, and open or closed as it was left.
- When a page asks to stay while its folder is being deleted with its tabs, the folder stays with what is left in it.
- Deleting a folder that holds every tab of the Space leaves the Space with no tabs.

## Acceptance checks

1. Run `make e2e E2E=folders`: `PASS folders.tree: tree=client/project/phase/[A]` shows folders made from the pinned section's menu and each folder's menu, named in place, with tab A dragged into the deepest one.
2. Run `make e2e E2E=folders`: `PASS folders.rename` shows a folder renamed by double-clicking it and another from its menu.
3. Run `make e2e E2E=folders`: `PASS folders.empty`, `PASS folders.delete-tabs` and `PASS folders.delete-keep` show an empty folder listed, a delete with tabs that asks first (Cancel keeps it), and a delete that keeps the tabs in the folder's place.
4. Run `make e2e E2E=folders`: `PASS folders.drag` and `PASS folders.collapse` show a today folder dragged into a pinned folder, and a closed folder that stays closed after a relaunch.
5. By hand: right-click a folder that holds an open tab, choose Delete Folder and Tabs, confirm, and check the tab closed and the folder is gone.

## Out of scope

- Folder icons, sharing folders, folder previews and live folders.
- Making a folder from several selected tabs at once.
- Zones, drop rules and the order of rows, covered in `sidebar.md`; saving the sidebar, covered in `sidebar-store.md`.
