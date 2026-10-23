# Importing from Arc

## Summary

People moving from Arc bring their Spaces, folders, pinned tabs and Favorites with them.
This spec covers how an Arc sidebar file is read, what a preview of the import shows, how the person's choices shape it, and how the result is written into the sidebar and taken out again.
The file picker and the wizard screens are separate pieces of work.

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
- Applying returns a record that takes the import out again in one transaction: the Favorites it added and the Spaces it created, with what is still inside them.
  Items the person moved out of an imported Space since stay put, and anything already gone is skipped.
  A new empty Favorites section made for a new profile stays behind, as it does when any Space of that profile is deleted.

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

## Out of scope

- Choosing the file, the consent text and the wizard and preview screens (the import wizard).
- The end to end run line for the import in the running app.
- Arc's archive, Little Arc, Easels, Notes, Boosts, cookies, passwords and history.
- Mapping Arc's theme colors and Space profiles onto Bow's own.
