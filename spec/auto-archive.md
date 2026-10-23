# Auto-archive

## Summary

Bow keeps the Today section of the sidebar clean: tabs that have not been used for a while move into an archive, where they stay until the person puts them back.
Each profile chooses how long "a while" is.
This spec covers the archive store and the rules that decide what archives; the settings menu, the archive list and the timer belong to the app and come later.

## Behavior

- Each profile has an auto-archive setting with a fixed menu: Never, 1 hour, 6 hours, 12 hours, 24 hours, 7 days, 30 days.
  A profile that never chose uses 12 hours.
  The setting belongs to the profile, so every Space of that profile archives on the same schedule.
- Only items in a Space's Today section (its unpinned tabs) are ever archived.
  Pinned tabs and Favorites are never archived, by auto-archive or by hand.
- A tab expires once it has been unused for at least the profile's threshold.
  A tab that is selected, or that the app asks to keep (for example one playing audio), stays.
  A tab whose last use is unknown stays.
- A split archives as a whole once every tab in it has expired, and never tab by tab.
  A folder in Today stays, and its tabs are judged one by one.
- Archived items live in their own file, `ArchivedItems.json`, next to the sidebar file and never inside it.
  The file is versioned.
  Each entry keeps the full item (with its custom title, and everything under it for a split or folder), when it was archived, why (auto or manual), and where it came from: the Space, the parent and the position.
- Putting an item back returns it to its old parent at its old position, with the same ID and title, and removes the entry.
- Archiving a tab by hand uses the same store and rules, with the reason manual.
- Time comes from an injectable clock, so tests and the end to end run can move it forward instead of waiting.

## Edge cases

- The old parent folder is gone: the item goes to the top of the same Space's Today.
  The Space is gone too: it goes to the top of the first Space's Today.
- A crash between writing the archive and changing the sidebar never loses a tab: the archive is written first, and a repeated archive replaces the entry instead of listing the tab twice.
  A crash while putting back leaves the tab in the sidebar and the entry in the archive, and the next put back just forgets the entry.
- An archive request that includes a pinned tab, a Favorite or an unknown item is refused as a whole and changes nothing.
- An archive file written by a newer version of Bow, or one that cannot be read, is moved aside untouched and the archive starts empty.
  A file with a few damaged entries keeps the readable ones and a copy of the original is kept beside it.
- A failed write leaves the archive as it was.

## Acceptance checks

1. With the 12 hour setting, a Today tab last used 11 hours ago stays and one last used 13 hours ago archives.
   Unit tests cover this with the manual clock; the end to end line is added with the app part.
2. Pin a tab and make a Favorite, then move the clock past every threshold.
   Neither archives.
3. Archive a split, change Today, then put the split back.
   It returns with both tabs, in its old position, and the sidebar passes its integrity check.
4. Open `ArchivedItems.json` after archiving.
   It has a `version` and the entry with its reason and source Space, and the sidebar file has no trace of the tab.
5. Later, with the app part, `make e2e` prints `PASS archive: clock+13h today=[] archived=[B] reopen=B`.

## Out of scope

- The settings menu, the archive list and Put Back controls, and the timer that runs auto-archive in the app.
- Page thumbnails and favicons for archived items.
- Clearing the archive by age and syncing it.
- Spaces and folders themselves: the sidebar store spec covers them.
