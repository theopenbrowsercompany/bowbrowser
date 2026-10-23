# Import bookmarks and history from Arc's Chromium profile

## Summary

Arc keeps bookmarks and history in standard Chromium profile files.
The importer reads them from a profile folder the person picks, so the command bar is useful from the first day.
This spec covers the reading side in BowCore; writing into the history store and the pinned section is a later step.

## Behavior

- The person picks a User Data folder. `Local State` lists the profiles (`profile.info_cache`): the folder name and the display name, with `Default` first and `Profile N` in numeric order.
- For one profile, `Bookmarks` is read as roots (bookmark bar, other, synced, and others such as Arc's `custom_root`), nested folders and URLs with their added dates.
- `History` is opened read only and copied with SQLite's online backup into a temporary database, which gives one consistent snapshot even while the browser is writing (committed WAL frames included, open transactions excluded). The snapshot is read, never the original. Its `urls` and `visits` tables become a list of visits in time order: URL, title, date, and Chromium's transition type.
- Only http and https visits are kept by default. `chrome://`, `file:` and `about:` pages are dropped.
- A dry run reports visit count, distinct pages, first and last visit, bookmark and folder counts, and any file that was missing or unreadable, without writing anything.
- Cookies, passwords and extensions are never read.

## Edge cases

- A missing `Local State`, `Bookmarks` or `History` is reported by name. In a dry run the other file is still summarized.
- Invalid JSON, a wrong shape, or a file that is not a SQLite database is reported as unreadable, never a crash.
- Bookmark entries with an unknown type, or a URL entry without a URL, are skipped. A zero or missing added date becomes no date.
- A browser writing to History in WAL mode does not matter: the snapshot holds the latest committed visits and the original is never modified.
- Visits with a zero or negative time have no usable date; they are left out and counted in the dry run's problems.

## Acceptance checks

1. A User Data folder with `Local State`, `Default/Bookmarks` and `Default/History` built from example.com fixtures: the dry run prints the expected counts.
2. The same folder without `History`: the dry run still counts bookmarks and names the missing file.
3. The original `History` file is byte for byte the same after a run.

## Out of scope

- Writing visits into the history store, and turning bookmarks into a pinned folder (an adapter maps `ChromiumVisit` into the store's visit record).
- Arc's sidebar file (spaces, pinned tabs); another importer covers it.
- Favicons, cookies, passwords, extensions.
