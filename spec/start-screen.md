# Start screen

## Summary

A Space with no tabs fills the page card with a calm start screen instead of a blank area: a greeting, a search pill that opens the command bar, the profile's Favorites as quick links, and a short hint.
Arc has no start page of its own (it opens the command bar), so the look follows Bow's styling guide while the actions stay Arc's: searching is the command bar, and the quick links are the Favorites.

## Behavior

- The start screen shows whenever the Space on screen has no tabs: after closing its last tab, on switching to a Space that has none, and in a new Space.
- Its parts sit centred in the page card, 26 points apart, top to bottom:
  - the Bow mark at 64 by 64 points;
  - a greeting in Fredoka 600 at 40 points in Text: "Good morning" from 5:00 until noon, "Good afternoon" from noon until 18:00, and "Good evening" from 18:00 until 5:00, by the Mac's local time;
  - a search pill 560 by 52 points, fully rounded, in the Search fill with a 1 point Line border, holding an 18 point magnifying glass and "Search or type a URL" at 16 points in Soft, 20 points in from its leading edge with 12 points between them;
  - the quick links, when the profile has Favorites: the first six Favorites in their sidebar order, in a row 18 points apart, each 76 points wide with a 56 point tile (16 point corners, Search fill, Line border) holding the site's icon, or the first letter of its name, at 24 points, and its name under it at 12.5 points in Soft on one line, cut with an ellipsis when too long;
  - a hint at 13 points in Soft: "<Space name> · press ⌘T to search".
  It carries no tab count: the screen only shows in an empty Space.
- Clicking the search pill, or pressing Return or Space while it has keyboard focus, opens the command bar empty, exactly as File > New Tab (Cmd+T) does.
  The pill is a button, not a text field: nothing is typed into it.
- Clicking a quick link shows that Favorite in place as the active tab, loading its saved address, as clicking its tile in the sidebar does; the start screen then gives way to the page.
- The greeting, the quick links and the hint are read again each time the window updates (a store change, a Space switch, a tab closing), so a Favorite added, removed or renamed, or a Space renamed, shows at once; nothing runs on a timer, and nothing animates.

## Edge cases

- No Favorites: the quick link row is not shown, and the hint follows the search pill.
- More than six Favorites: only the first six in sidebar order show; removing one while the screen shows brings the next one in.
- A Space name longer than 40 characters is cut to 39 with an ellipsis in the hint; an empty name reads "Space".
- A narrow window: every part stays at least 24 points inside the card; the pill shrinks below 560 points, the greeting and hint truncate, and quick links that do not fit are left out from the end.
- Switching from one empty Space to another updates the hint and the quick links to the new Space and its profile.
- Dark appearance: the page card stays White and draws light, so the start screen does too; its colors are light and dark tokens and would follow a dark card.
- A Space whose active tab has no page (a Favorite or pinned tab the person closed) shows the unloaded tab state with Load Tab, not the start screen.
- The greeting reflects the hour at the last window update; a screen left open across 12:00 updates on the next change.

## Acceptance checks

1. Switch to a new empty Space named "Work Space" with no Favorites: the start screen shows the 64 point mark, the greeting for the current hour, the 560 by 52 pill and "Work Space · press ⌘T to search", and no quick links.
2. Click the pill: the command bar opens empty, as Cmd+T opens it.
3. Add seven Favorites: six quick links show, in sidebar order, each a 56 point tile with 16 point corners.
4. Remove the first Favorite while the screen shows: the row now starts with the second and ends with the seventh.
5. Click the second quick link: that Favorite becomes the active tab and its page shows.
6. Narrow the window to 640 points: everything stays inside the card, the pill is narrower than 560 points and fewer links show.
7. `make e2e E2E=design.start_screen` prints PASS for `design.start_greeting`, `design.start_hint`, `design.start_search`, `design.start_links`, `design.start_layout`, `design.start_narrow` and `design.start_dark`.

## Out of scope

- Typing into the pill, suggestions on the start screen, and editing quick links there (they are the Favorites, edited in the sidebar, see `favorites.md`).
- A greeting that names the person, a background picture, or per Space themes on the start screen.
- The command bar itself, covered in `command-bar.md`.
