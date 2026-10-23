# History

## Summary

Bow remembers the pages a person visits, separately for each profile, so the command bar can offer them back.
Private (ephemeral) profiles remember nothing on disk.

## Behavior

- Each profile has its own history.
  Pages visited in one space's profile never show up in another profile's history.
- A page is recorded when its navigation commits, with its address, its title and the time.
  The title is filled in as soon as the page reports one, and a later title replaces an earlier one.
- Visiting the same page again adds a visit to the same entry instead of a second entry.
  Each entry knows how many times it was visited, how many of those visits were typed or chosen in the address bar or command bar, and when it was last visited.
- Reloading a page, and going back or forward to it, do not count as new visits.
- Redirects count once, as the page where they end.
  Navigations that start but fail or get cancelled leave nothing behind.
- Only web pages (http and https) and local files are recorded.
  Internal pages, `about:` pages, `data:` pages and scripts are never recorded.
- The part of an address after `#` does not make a different page.
- Recent history lists pages newest first.
- Searching takes what was typed, splits it into words, and returns pages whose address or title contains every word, ignoring case.
  Better matches come first: pages visited more often (typed visits count extra), then more recent ones.
  Searching for nothing returns nothing, and characters such as `%` and `_` search for themselves.
- A page can be forgotten with all its visits, a span of time can be forgotten, and the whole history can be cleared.
  Forgetting a span leaves the other visits of a page in place and a page with no visits left disappears.
- Every tab feeds the history of its own profile, in any window, so a tab in one space never records into another space's profile.
- A page appears in history as soon as its navigation commits, and its title fills in when the page reports it.
- The command bar offers history below open tabs: a page that is open in a tab is shown as the tab, and a blank bar offers no history.
- Persistent profiles keep their history in a file inside the profile's own folder, so it survives quitting and relaunching.
  Ephemeral profiles keep it in memory only, and it is gone when the profile closes.

## Edge cases

- A history file that cannot be opened is reported once on standard error, and that profile records nothing for the run.
- A profile the engine cannot describe is treated as ephemeral, so nothing is written to disk for it.
- A profile name with odd characters (slashes, dots) still gets its own safe folder inside the history folder.
- A history file written by a newer version of Bow is refused instead of being damaged.
- Several tabs recording at once never lose or double count visits.
- An empty or missing title never erases a title the page already had.

## Acceptance checks

1. In a persistent profile, open two pages, quit and relaunch.
   Recent history lists both, newest first, with their titles.
2. Open a page, reload it and go back to it.
   Its visit count stays at one.
3. Type part of a page's title into history search.
   The page is returned, and a word that matches nothing returns nothing.
4. In an ephemeral profile, open pages and look in the app's data folder.
   No history file exists, and relaunching shows no history.
5. Forget one page.
   It no longer appears in recent history or search, and other pages remain.

6. In a private (ephemeral) profile, open two pages.
   Its history lists both while Bow runs, and no history folder or file appears in Bow's data folder.

## Out of scope

- Showing history in the command bar and a history window: the command bar spec covers results, and history UI is not built yet.
- Importing history from other browsers.
- Favicons and sync.
