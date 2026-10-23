# Importing from Arc

## Summary

People moving from Arc bring their Spaces, folders, pinned tabs and Favorites with them.
This spec covers how an Arc sidebar file is read, what a preview of the import shows, how the person's choices shape it, and how the result is written into the sidebar and taken out again.
The wizard that walks through it is described below.

## Behavior

- The person chooses Arc's sidebar file themselves.
  Nothing reads Arc's data without that choice, and reading never changes the file.
- Every Arc Space becomes one imported Space with its title, icon (an emoji or a named symbol), theme style and appearance, and the browser profile it belonged to.
  Spaces keep the order they have in Arc.
- Pinned items keep Arc's order and structure.
  Pinned tabs that sit outside any folder stay at the top level, next to the folders.
- Folders keep their name and icon, and nest to any practical depth.
  A folder with nothing in it is still imported as an empty folder.
- A pinned tab keeps its saved address and its saved page title.
  When the person had renamed the tab in Arc, the new name is kept as a custom name.
  A tab that only shows its page title has no custom name.
- A split view is imported as one item that holds its tabs, with its direction, pane widths and focused pane when Arc recorded them.
  A split view takes two to four tabs, like the ones Bow makes: one that is left with a single tab (its other contents were folders or tabs with no saved address) imports as that plain tab, and tabs past the fourth import as plain tabs right after the split, in order. Both are listed in the report and shown that way in the preview, so what the person approves is what arrives.
- Each Space's unpinned tabs are read too, so a later step can offer them.
- Favorites stay grouped by the profile they belong to, because Arc keeps a separate Favorites list per profile.
- A dry run reads the file and produces a report without importing anything.
  The report counts Spaces, folders (including empty ones and the deepest nesting), pinned tabs, unpinned tabs, Favorites, split views and custom names.
  It also lists everything left out, each with a reason and a name the person can recognize.
- The report can be shown as a few readable lines, and as one summary line such as `spaces=3 folders=5 depth=3 pinned=18`.
- These are left out and listed in the report: Live Folders, Easels, Notes, shared items, kinds of items this version does not know, tabs with no saved address, split views with no tabs, and items that only appear in Arc's private windows, Little Arc or other windows' containers.
- Cookies, saved passwords and extensions are never part of any import.
  History and bookmarks come only through their own step (see History and bookmarks).

## Choices, preview and applying

- The wizard never reads Arc's data silently: the person picks the file, sees a preview, and only then does anything change.
  A preview is built from the parsed file and the person's choices, and has no side effects.
- The person picks how Spaces come across, copying Dia's three options:
  - Skip Spaces: no Spaces and no pinned tabs. Only the Favorites of Arc's default profile come across, into Bow's default profile.
  - Each Space as a profile: every chosen Arc Space becomes a Space with a profile of its own, each with a new distinct profile ID.
    Bow has no profile management yet, so the profile is only an ID that keeps the Space's Favorites apart.
    Each such Space gets its own copy of the Favorites of the Arc profile it belonged to, because Arc showed those Favorites in it.
  - Arc Spaces as Spaces: every chosen Arc Space becomes a Space.
    Spaces that shared an Arc profile share one Bow profile and one Favorites list, and a second import of the same Arc profile lands in that same profile.
- A checkbox per Arc Space picks which Spaces to bring.
  Leaving every Space unchecked imports nothing.
- Favorites come with the Spaces that show them.
  When no brought Space uses an Arc profile, that profile's Favorites are not brought and the preview says so.
  The person can also leave Favorites out.
- Unpinned tabs are left out unless the person asks for them.
- Items rescued from Arc's orphans come along as one folder named "Recovered from Arc" at the end of the first brought Space, unless the person leaves them out.
- A Space with an empty name gets a generic name.
- The preview lists the tree of each Space and of the Favorites with nesting, empty folders, custom names and split views, and counts folders, tabs and Favorites.
  It also lists everything the person's choices leave out, each with a reason, and passes on what the file reading already left out.
  One summary line reports the deepest folder chain with the first tab inside it and the Favorites count, such as `tree=client/project/phase/[A] favorites=4`.
- Applying the preview adds the Spaces and Favorites to the sidebar as one transaction: everything arrives and the file is saved once, or nothing changes.
  Imported Spaces go after the Spaces already there, and the active Space and tab stay as they were.
  The sidebar after applying shows exactly the tree the preview showed.
- Folder icons, Space icons and themes, split pane widths and the focused pane are shown or read but not stored yet, because the sidebar has nowhere to keep them.
- Applying returns a record that takes the import out again in one transaction, and the record knows exactly which items the import inserted.
  Undo deletes only those, so it never removes anything the person added or moved since:
  - Anything else found inside an imported Space (an existing tab or folder moved in, a tab opened there) moves, with what is inside it, to the end of the same section (pinned or unpinned) of the first Space that is not an imported one, in the order it had.
    Then the imported Space is deleted, and if an imported Space was on screen, that first Space comes on screen instead.
    Kept items take the profile of the Space they move to, which matters when the imported Space had a profile of its own.
  - Items the person moved out of an imported Space stay where they are now, and anything already gone is skipped.
  - The Favorites the import added are deleted, except one the person moved out of the Favorites section it was added to.
  - If only imported Spaces are left, there is no Space to take what the person added, so undo is refused with a clear reason and changes nothing.
  - If writing the file fails, the undo still happened in the sidebar and the result carries the failure, the same way applying does.
  - A Favorites section the import made for a new profile is removed with it when it is empty and no Space uses the profile; one the person has since put a Favorite in, or a Space of theirs now uses, stays.
- Applying never repeats a Favorite: one the profile's Favorites already has at the same address is left out, and the preview lists it as already there.
  Importing the same file twice therefore adds the Spaces again but no Favorites.

## The wizard

- File > Import from Arc… opens a sheet on the window, one at a time across all windows.
- The first screen says what is read (the sidebar file the person picks: Spaces, folders, pinned tabs and Favorites; and, for history and bookmarks, only Local State, Bookmarks and a copy of History from Arc's User Data folder), that nothing leaves the Mac, that cookies, passwords and extensions are not read and Arc's files are never changed, and that a preview comes first.
  Its buttons are Cancel, History and Bookmarks… and Choose File….
  Nothing is read until Choose File… or History and Bookmarks… is pressed and the person picks.
  The file picker starts in the folder where Arc keeps its sidebar file as a suggestion only; the app never opens that folder itself.
- A file that is not JSON, not an Arc sidebar file, or empty of Spaces and Favorites stops at a message and changes nothing.
- The Spaces screen has the three modes (default: Arc Spaces as Spaces), one checkbox per Arc Space (off when Spaces are skipped), and Favorites and unpinned tabs checkboxes.
  Continue is off while the choices bring nothing.
- The preview screen shows the counts, the tree of Spaces, folders and tabs with nesting, then the Favorites, and what the choices leave out.
- Import adds everything in one step and registers the profiles the new Spaces use; if that fails the import is taken out again.
  The last screen offers Undo, which gives back the sidebar as it was, History and Bookmarks… (see below), and Done.
  Undo is offered only on that screen: once it is closed, the import stays.
- An Arc profile folder name becomes a Bow profile ID the engine accepts: `arc-`, a lowercase slug of the name, and a short stable hash of the exact name, such as `arc-profile-1-ef0ccd1ac1`.
  The engine allows only letters, digits, dot, underscore and hyphen in an ID and treats folder names without regard to case, so names that differ only in case or punctuation get different IDs, and the same name gets the same ID on every import.

## History and bookmarks

Arc keeps history and bookmarks in standard Chromium profile files inside its User Data folder, apart from the sidebar file.
Bringing them makes the command bar's history results useful from the first day.

- The step runs from the same wizard: History and Bookmarks… on the first screen runs it on its own, and the same button on the sidebar import's last screen runs it after that import.
  It runs once per wizard.
- The person picks Arc's User Data folder in a folder picker that starts where Arc keeps it, as a suggestion only.
  Nothing is read before the pick.
- Exactly these files are read, and no other:
  - `Local State` at the top of the folder, for the list of profiles (`profile.info_cache`);
  - `Bookmarks` in each listed profile's folder, read whole as JSON;
  - `History` in each listed profile's folder, with its `History-wal` and `History-journal` files when they are there, copied byte for byte into a folder of this Bow process's own inside its data directory (`Import Scratch/<process ID>`), never a temporary folder another Bow shares.
    SQLite opens only the copy: once to fold the copied side files into it, then read only to read the `urls` and `visits` tables.
    The copy is deleted as soon as it is read, whether the read worked or not.
    A process deletes its own folder when it quits, and at launch only the folders of Bow processes no longer running, so one Bow starting or quitting never deletes another's copy mid-read.
  - `Cookies`, `Login Data`, `Web Data`, `Extensions` and every other file are never opened, and Arc's folder is never written to.
- A folder with no `Local State`, or one that is not Chromium's, or one that lists no profile, stops at a message that says so, with Choose Another Folder….
  A profile whose History or Bookmarks is missing, locked or damaged still brings what could be read, and the preview names the problem.
- Each Chromium profile maps to a Bow profile: `Default` to Bow's default profile, and any other to the profile a sidebar import made for that Arc profile (the same ID, see the profile ID rule above).
  When Bow has no such profile, the profile's history goes to the profile of the Space on screen, and the preview says so.
- Visits keep their time (Chromium stores microseconds since 1601 UTC), the page title and whether the address was typed.
  Pages that are not web pages (`chrome://`, `file:` and the like), loads inside frames, reloads, and visits without a usable time are left out, the same visits Bow itself would not record.
  An imported title names a page only when it has no title yet.
  Visits go in 500 at a time, each batch its own transaction, so a page load or a search on the same profile waits for one batch at most.
  A batch that fails takes out the batches before it, and Undo takes out every batch together.
- The preview lists, per profile, the visits and bookmarks it brings and the Bow profile it goes to, then any problem.
  A choice sets what happens to bookmarks: Bookmarks as a pinned folder (the default) or Skip bookmarks.
  Cookies, passwords and extensions are not imported, and the preview says so.
- Bookmarks as a pinned folder puts one folder named `Arc Bookmarks` (followed by the profile's name in parentheses when more than one profile brings bookmarks) in the pinned section of a Space: the Space on screen when it uses the profile's Bow profile, else the first Space that does, else the Space on screen.
  Inside, each bookmark root that holds anything (Bookmarks bar, Other bookmarks, Mobile bookmarks) is a folder, with the bookmarks and folders in their order and nesting.
- Nothing is imported twice: a visit to the same page at the same time is already there, and a folder of the same name at the same place is reused, with a bookmark whose address is already a tab directly in it left out.
  Importing the same folder again adds nothing, and the last screen says how much was already there.
- Undo on the last screen takes out everything the wizard added, in one go: the sidebar import and the bookmarks folder in one sidebar transaction (bookmarks first), then exactly the visits the import added, by their row and time.
  A visit the person made since, even to an imported page, stays, and so does anything the person put in the bookmarks folder (with the folders around it) or moved out of it.
  If the sidebar part is refused, nothing is undone, the visits included, so Undo can be tried again.
- Closing the window mid-read stops the read before its next profile and changes nothing.

## Edge cases

- A file that is not JSON, or JSON that is not an Arc sidebar file, is refused with a clear reason and nothing is imported.
- A file with no Spaces imports nothing and reports zero.
- A damaged entry (wrong shape, an id that does not match its key, a missing item, an odd number of values in a key and value list) is skipped and reported, and the rest of the file still imports.
- When Arc's record of which folder holds an item disagrees with itself, the item's own pointer to its folder decides.
  An item that points at an existing folder but is not listed by it still shows up in that folder, after the listed ones.
- An item listed in two places appears once, and the report notes the repeat.
- Items that belong to no Space and no folder are orphans.
  By default they are kept together as recovered items, the way Arc itself gathers them.
  The person can choose to drop them instead, and the report then lists them.
- Items that belong to containers no Space uses, such as another computer's unpinned tabs, are listed as unreachable instead of imported.
- Folder nesting beyond 64 levels is cut off and reported, so a broken file cannot hang the import.
- A tab title and a pinned tab name that match count as no rename.

## Acceptance checks

1. Open a prepared Arc sidebar file with three Spaces, five folders nested three deep and eighteen pinned tabs, and run a dry run.
   The summary line reads `spaces=3 folders=5 depth=3 pinned=18`.
2. Run the dry run on a file with an empty folder.
   The folder count includes it and the report's empty folder count is one.
3. Run the dry run on a file with one Live Folder and one Easel.
   Neither is imported and each appears in the skipped list with its reason.
4. Parse a file where a pinned tab has a different title from the page title it saved.
   The imported tab has a custom name; a tab with matching names has none.
5. Parse a file with Favorites for two profiles.
   Each profile's Favorites come back as a separate list.
6. Run the dry run on text that is not JSON.
   It fails with an invalid file reason and reports nothing.
7. Run the dry run twice on the same file.
   Both reports are identical and the file is unchanged.

8. Choose Arc Spaces as Spaces on a file with a folder client holding project, which holds phase, which holds a tab titled A, and four Favorites, then apply.
   The summary line reads `tree=client/project/phase/[A] favorites=4`, and the sidebar shows that same tree.
9. Pick only two of three Spaces.
   The third is missing from the preview and the sidebar and is listed as not selected.
10. Choose each Space as a profile.
    Every imported Space has a different profile ID.
11. Apply an import, then undo it.
    The sidebar is as it was before.
12. Apply an import, then move one of your own folders into an imported Space and open a tab in it, then undo.
    Both are still there, in the same section of your first Space, and everything the import added is gone.
13. Apply an import, move one imported Favorite into one of your Spaces, then undo.
    That Favorite stays where you put it and the other imported Favorites are gone.
14. Apply an import and delete your own Spaces, then undo.
    Undo is refused with a reason and nothing changes.
15. Make the sidebar file unwritable, apply and undo.
    Each reports the failure and the sidebar still shows the change.
16. Import a file with Arc profiles named `Profile 1` and `profile 1`.
    Their Bow profile IDs differ, even when compared without regard to case, and use only letters, digits, dot, underscore and hyphen.
17. Run the wizard on a fixture file of two Spaces: consent, choose the file, untick a Space and see it leave the preview, import, then Undo.
    `import.apply` passes: the sidebar shows the preview's tree and Undo restores the sidebar exactly.
18. Import the same file twice: the second preview lists the Favorites as already there and the sidebar keeps one copy.
19. Choose a JSON file that is not an Arc sidebar file: the wizard says so and the sidebar is unchanged.
20. Run History and Bookmarks… on a User Data folder with a Default profile and one with no Bow profile.
    `import.history` passes: visits>0, the Default visits are in the default profile's history, the other profile's in the profile of the Space on screen as the preview said, and the command bar finds an imported page.
21. With Bookmarks as a pinned folder, the pinned section of the Space on screen gains `Arc Bookmarks` with the bookmark tree's nesting (`import.history_bookmarks`).
22. Only `Local State`, `Bookmarks` and copies of `History` are opened, never the decoy Cookies and Login Data beside them, and the copies are gone afterwards (`import.history_files`).
23. Undo takes out the visits and the folder and leaves the sidebar and both histories as they were (`import.history_undo`).
24. With Skip bookmarks the sidebar is unchanged; importing the same folder again adds no visit (`import.history_skip`, `import.history_twice`).

## Out of scope

- Undoing an import after its wizard screen is closed.
- Arc's archive, Little Arc, Easels, Notes, Boosts, cookies, passwords and extensions.
- Importing history or bookmarks from browsers other than Arc, and any Chromium file other than the three named above.
- Mapping Arc's theme colors and Space profiles onto Bow's own.
