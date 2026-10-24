# Profiles

## Summary

A profile is a separate set of cookies, logins, site data and history.
Every Space shows exactly one profile, and several Spaces may show the same one, so a person keeps one login across the Spaces they want it in and a fully separate login in the others.

## Behavior

- Bow always has a default profile.
  It cannot be deleted, and Spaces that were saved before profiles existed use it.
- A profile has a name the person sees and can change.
  Names are trimmed and cannot be empty; two profiles may share a name.
- A profile is persistent or temporary.
  A persistent profile keeps its data on disk between launches.
  A temporary profile keeps it in memory only and loses it when Bow quits.
- Each persistent profile keeps its data in its own folder, directly inside Bow's browser data folder: `Default` for the default profile and `Profile-<id>` for every other.
  A profile is set up once, the first time one of its Spaces is shown, and every Space on that profile uses the same one.
- A profile's ID is chosen when it is created, from the name or from a suggested name (for example an imported Arc profile's folder name), and never changes, even when the profile is renamed.
  It contains only ASCII letters, digits, `.`, `_` and `-`: other characters become `-`, letters become lower case, and it is shortened to 48 characters.
  `Profile 1` becomes `profile-1`.
  Two IDs never differ only in letter case, and `default` is taken, so a clash gets a number added: `work`, `work-2`.
  The number never pushes an ID past 48 characters.
  An ID chosen elsewhere, such as an imported Arc profile's (`arc-<name>-<hash>`, up to 47 characters), is kept exactly as given when it is valid; if a different profile already has it in another letter case it is refused, and asking for the same ID again returns the profile that has it.
- Beside its ID, every profile (the default and temporary ones too) has a storage identity: a UUID given once, when the profile is made, and never changed, not by a rename and not by a relaunch.
  No two profiles share one.
  It names the profile's storage and, once Bow has them, its extensions, which belong to the profile like its logins, cookies and history, so every Space on the profile shares them, as in Arc.
  A profile registered again under a deleted profile's ID gets a new one.
  Profiles saved by a Bow from before storage identities get theirs the first time a newer Bow opens the profiles file, which it saves at once, so each profile gets its identity only once.
- A Space chooses its profile in the Space menu (the context menu of the Space's name), as Arc sets one per Space from the Space's menu ([Arc Help: Profiles](https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing)).
  "Profile" lists every profile, the default first, with a check by the one the Space shows, then "New Profile…".
  "New Profile…" asks for a name in a sheet, creates a persistent profile with that name and puts the Space on it; an empty name or Cancel changes nothing.
  Choosing "Default" takes a Space back to the default profile.
- Putting a Space on another profile closes the Space's open pages first, each running its leave prompt, then changes the profile; the active tab loads its address again in the new profile at once, and the other tabs load there when chosen.
  A page whose person chooses to stay keeps the whole Space on its old profile, so no page runs in a profile its Space does not show.
  Choosing the profile the Space already shows does nothing.
- Favorites belong to a profile, not a Space: a Space put on another profile shows that profile's Favorites, and a selected Favorite of the old profile gives way to the Space's own tab.
- A profile's storage is set up the first time one of its Spaces shows a tab, and checked first: its folder must sit directly in the browser data folder and, if it is already there, be writable.
  A profile that fails the check opens nothing, and Bow says the Space's profile is not available, rather than running its pages in memory or in another profile.
- Two Spaces on the same profile share cookies and logins.
  Two Spaces on different profiles share nothing.
- A tab row's menu has "Move to Space", a submenu of every other Space, as Arc's tab menu moves a tab between Spaces.
  The tab goes to the top of the same section (pinned or today) of that Space, and the Space on screen stays on screen; if the moved tab was selected, the Space selects its own tab instead.
  Favorites, folders and splits have no "Move to Space" (a Favorite leaves Favorites with "Remove from Favorites").
- Dropping a tab row from the sidebar on another Space's icon in the footer switcher does the same as "Move to Space" for that Space, through the same code: same profile keeps the live page, another profile asks first.
  While the drag is over an icon that would take it, the icon shows its ring (the ring the Space on screen has).
  Dropping on the icon of the Space on screen, a folder, a split, a Favorite, or anything dragged from another window or app is refused: no ring, and nothing changes.
  A drag that leaves the icon without a drop clears the ring and moves nothing.
- Moving a tab to another Space of the same profile keeps its live page: it does not reload, and the page keeps its state and logins.
- Moving a tab to a Space of a different profile asks first, in a sheet on the window, every time; there is no "don't ask again", because the page loads again under different logins.
  The sheet names the tab, the Space and both profiles, with Move and Cancel.
  Move closes the tab's page, running its leave prompt, then moves the tab; it loads its address again in the new profile when it is next shown, so the page starts over there and is not logged in unless that profile is.
  Cancel, or Stay at the page's leave prompt, leaves the tab where it was with its live page.
  A move stops, with the tab where it was, when the window closes or Bow quits during it; those close the page themselves, so it is never asked twice.
- Favorites refuse a tab from another profile: dropping a tab of a Space on another profile into Favorites, putting another profile's Favorite in, and taking a Favorite out into a Space of another profile are all refused and change nothing.
- A Favorite selected when the person switches to a Space of another profile, which cannot show it, is remembered by the Space being left, so switching back selects it again, as Arc returns each Space to the tab it was on.
  A Space of the same profile shows the same Favorites, so the Favorite simply stays selected there.
- The Space menu's "Profile" submenu ends with "Delete Profile…", a submenu of every profile but the default (Arc deletes profiles in its settings, which Bow does not have yet).
  Only a profile that no Space in any window shows is enabled, and "Delete Profile…" itself is greyed out when there is none.
  Choosing one asks in a sheet, with a red "Delete Profile" button and Cancel (Return answers Cancel); deleting takes it out of the list at once.
- A profile that a Space still shows cannot be deleted.
- Deleting a profile takes it out of the list at once but removes its folder only the next time Bow starts, once its first window is open and before any other profile is set up, because browsers may still be using it until then (a deleted profile is never set up again, so no browser of it exists in the new run).
  A deleted profile's ID is never given to a new profile, not after its folder is gone and not after a relaunch, because history, site permissions and Favorites are saved under the ID and a new profile would inherit them.
  Any `Profile-<id>` folder already on disk also counts as taken when choosing an ID.
  The one way an old ID comes back is an import that puts a Space on that profile again: the profile is registered again under the same ID and its folder, if still there, is kept.
  At the next launch a folder whose profile a Space shows again is not deleted, and stays on the list until that profile is registered again.
  A folder that cannot be removed is tried again at the following launch.
  A temporary profile has no folder, so deleting it is immediate.
- The list of profiles with their storage identities, the folders waiting for deletion and the retired IDs are saved together in `Profiles.json` in Bow's Application Support folder, apart from the sidebar file.
  Every change is written at once.

## Edge cases

- A new profile whose name has no usable characters gets the ID `profile`.
- A Space pointing at a profile that is not in the list (for example after an unreadable profiles file was set aside) has no storage to show.
  Bow picks a profile for it instead of guessing one, and never opens that Space's tabs in another profile silently.
- A profiles file that cannot be read, or was written by a newer Bow, is moved aside under a new name, never overwritten, and Bow starts with only the default profile.
  The list of folders waiting for deletion is lost with it, so those folders stay on disk until the person removes them.
  Their IDs are still not reused while their folders are on disk; the IDs of profiles whose folders were already gone (and of temporary profiles) are forgotten with the file.
- A hand edited file is cleaned when read: entries with an invalid ID, an empty name or an ID matching another in letter case are dropped, the default profile is restored, and folders to delete must look like `Profile-<id>`, so no other path is ever removed.
  A profile in it with no storage identity, one that is not a UUID, or one an earlier profile in the file already has gets a new one (the earlier profile keeps it), and the file is saved at once.
- A folder to delete that is already gone is simply forgotten.
- Moving a tab within one Space never reloads it.

## Acceptance checks

1. Create "Work" and "Personal" and a Space on each: Work's folder is `Profile-work`, Personal's is `Profile-personal`, and both sit directly inside the browser data folder.
2. Sign in to a site in the Work Space: a Space on Personal does not see the cookie, and a second Space on Work does.
3. Move a tab between two Spaces on Work: it keeps its live page without reloading.
4. Move a tab from a Work Space to a Personal Space: Bow asks first; agreeing reloads the address there, declining leaves the tab where it was.
5. Create "work" twice and "WORK" once: the IDs are `work`, `work-2` and `work-3`.
6. Try to delete a profile a Space still shows: Bow refuses. Move the Space off it, delete the profile, and its folder is still on disk; quit and start Bow again and the folder is gone.
7. Type in a draft that asks before leaving, then choose "Profile > New Profile…" in its Space's menu and answer Stay: the Space keeps its profile and the draft. Choose the new profile and leave: the active tab loads again in it, and the menu checks it.
8. Run `make e2e`: `profiles` prints `PASS profiles: work_cookie=1 personal_cookie=none shared=1`, and `profiles.spaces` passes.
9. Type in a page, then Move to Space to another Space on the same profile: no question, and there the same page shows with the text still typed.
10. Move to Space to a Space on another profile, answer Cancel, and ask again: it asks again and the tab stays with its page. With a draft that asks before leaving, answer Move and then Stay: the draft stays where it was.
11. Drop a tab of a Space on another profile onto the Favorites: nothing moves. A tab of a Space on the same profile goes in.
12. Select a Favorite, switch to a Space on another profile and back: the Favorite is selected again.
13. Run `make e2e`: `profiles.move_same`, `profiles.move_other`, `profiles.move_cancel`, `profiles.move_stay`, `profiles.favorites_refuse` and `profiles.delete_next_launch` pass.

## Out of scope

- Dragging a tab onto a Space in the Space switcher to move it (Bow has no such drop yet), and the sidebar's drawing of profiles.
- A settings window listing profiles; deleting happens from the Space menu until there is one.
- Sharing Favorites between Spaces of one profile (see `sidebar-store.md`).
- Importing Arc profiles into the list (see `arc-import.md`); the import suggests names and this feature turns them into IDs.
- Clearing a profile's data without deleting it, and moving data between profiles.
