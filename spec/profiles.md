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
- Moving a tab to another Space of the same profile keeps its live page: it does not reload, and the page keeps its state and logins.
- Moving a tab to a Space of a different profile asks first.
  If the person agrees, the tab loads its address again in the new profile, so the page starts over there and is not logged in unless that profile is.
  If they decline, nothing moves.
- A profile that a Space still shows cannot be deleted.
- Deleting a profile takes it out of the list at once but removes its folder only the next time Bow starts, before any browser opens, because browsers may still be using it until then.
  A deleted profile's ID is never given to a new profile, not after its folder is gone and not after a relaunch, because history, site permissions and Favorites are saved under the ID and a new profile would inherit them.
  Any `Profile-<id>` folder already on disk also counts as taken when choosing an ID.
  The one way an old ID comes back is an import that puts a Space on that profile again: the profile is registered again under the same ID and its folder, if still there, is kept.
  At the next launch a folder whose profile a Space shows again is not deleted, and stays on the list until that profile is registered again.
  A folder that cannot be removed is tried again at the following launch.
  A temporary profile has no folder, so deleting it is immediate.
- The list of profiles, the folders waiting for deletion and the retired IDs are saved together in `Profiles.json` in Bow's Application Support folder, apart from the sidebar file.
  Every change is written at once.

## Edge cases

- A new profile whose name has no usable characters gets the ID `profile`.
- A Space pointing at a profile that is not in the list (for example after an unreadable profiles file was set aside) has no storage to show.
  Bow picks a profile for it instead of guessing one, and never opens that Space's tabs in another profile silently.
- A profiles file that cannot be read, or was written by a newer Bow, is moved aside under a new name, never overwritten, and Bow starts with only the default profile.
  The list of folders waiting for deletion is lost with it, so those folders stay on disk until the person removes them.
  Their IDs are still not reused while their folders are on disk; the IDs of profiles whose folders were already gone (and of temporary profiles) are forgotten with the file.
- A hand edited file is cleaned when read: entries with an invalid ID, an empty name or an ID matching another in letter case are dropped, the default profile is restored, and folders to delete must look like `Profile-<id>`, so no other path is ever removed.
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

## Out of scope

- The confirmation dialog when a tab moves to a Space of another profile, deleting profiles from the app, and the sidebar's drawing of profiles (the next part of this feature).
- Sharing Favorites between Spaces of one profile (see `sidebar-store.md`).
- Importing Arc profiles into the list (see `arc-import.md`); the import suggests names and this feature turns them into IDs.
- Clearing a profile's data without deleting it, and moving data between profiles.
