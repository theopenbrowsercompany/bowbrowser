# Importing from Arc

## Summary

People moving from Arc bring their Spaces, folders, pinned tabs and Favorites with them.
This spec covers how an Arc sidebar file is read and what a preview of the import reports.
The file picker, the import wizard and applying the result to the sidebar are separate pieces of work.

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
- Each Space's unpinned tabs are read too, so a later step can offer them.
- Favorites stay grouped by the profile they belong to, because Arc keeps a separate Favorites list per profile.
- A dry run reads the file and produces a report without importing anything.
  The report counts Spaces, folders (including empty ones and the deepest nesting), pinned tabs, unpinned tabs, Favorites, split views and custom names.
  It also lists everything left out, each with a reason and a name the person can recognize.
- The report can be shown as a few readable lines, and as one summary line such as `spaces=3 folders=5 depth=3 pinned=18`.
- These are left out and listed in the report: Live Folders, Easels, Notes, shared items, kinds of items this version does not know, tabs with no saved address, split views with no tabs, and items that only appear in Arc's private windows, Little Arc or other windows' containers.
- Cookies, saved passwords and history are never part of this import.

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

## Out of scope

- Choosing the file, the import preview screen, selecting which Spaces to bring, and writing the result into the sidebar (the sidebar and spaces specs, and the import wizard).
- The end to end run line for the import, which needs the app.
- Arc's archive, Little Arc, Easels, Notes, Boosts, cookies, passwords and history.
- Mapping Arc's theme colors and Space profiles onto Bow's own.
