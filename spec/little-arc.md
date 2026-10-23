# Little Arc

## Summary

Little Arc is a small floating window for links clicked in other apps (Slack, Mail, a chat), so a quick look does not add a tab to the person's Spaces.
The person reads the page and closes the window, or moves the page into a Space with one key, where it keeps running as it was.

## Behavior

### Opening

- The setting "Links from other apps open in Little Arc" is on unless the person turns it off, as in Arc.
  It is stored as `littleArc.opensExternalLinks` in the app's settings; there is no settings window for it yet.
- While it is on and a browser window is open, each link another app sends opens in a new Little Arc window of its own.
  Links Bow kept while starting open the same way, in order, once the first window is open.
- The page opens in the profile of the Space on screen in the browser window links go to (the main window, else the last one shown), the same profile a link opens in without Little Arc.
- Little Arc is a floating panel that stays above other windows.
  It opens centered on the display under the pointer (the app the link was clicked in), else the display of the key window, at about 900 by 660 points, smaller on a small display, and on the macOS Space in use, also over a full screen app.
  It comes forward and takes the keyboard, so the person can read and scroll at once.
- The browser window is left as it was: no tab opens in it, and its Space and shown tab stay the same.
- Little Arc has a compact toolbar in its title bar: the page's host, a Move menu and an Open in Bow button.
- With the setting off, or with no browser window open, a link opens as it did before Little Arc: a new tab in the browser window's Space on screen, or a new window (see `spec/link-routing.md`).

### Moving the page into a Space

- Open in Bow (the toolbar button, or Cmd+O while Little Arc is in front) moves the page into the Space the browser window shows.
- The Move menu lists every Space of the browser window in sidebar order, the Space on screen checked.
  Choosing one, or pressing Ctrl and its number (Ctrl+1 to Ctrl+9, the numbers Bow uses for Spaces) while Little Arc is in front, moves the page into that Space.
- A move shows the chosen Space in the browser window, adds the page as a new tab in its Today section (after the selected Today tab, as a link opens), selects it, closes Little Arc and brings the window forward.
- The page is moved, never reloaded: its scroll position, form text, logins and media keep going.
- A Space of another profile is listed but disabled: a live page cannot change profile.
  Open in Bow does nothing (a beep) while the Space on screen has another profile.

### Closing

- Closing Little Arc (its close button, Cmd+W or Close Window) closes its page; nothing is kept or archived.
- A page that asks before leaving asks first: Stay keeps Little Arc and its page as they were, Leave closes both.
- Little Arc also closes when its page closes itself and when Bow quits.

## Edge cases

- Several links open several Little Arc windows, each on its own page.
- A move while the page's leave prompt is open (a close is under way) does nothing; the person answers the prompt first.
- A move when the browser window has closed meanwhile goes to the window links now go to; with no window open the page stays in Little Arc and Open in Bow beeps.
- The browser window switching Spaces while Little Arc is open changes where Open in Bow moves the page: it always follows the Space on screen at the moment of the move.
- Quitting with Little Arc open closes its page with every other page; a page that asks before leaving can cancel the quit, as any page can, and Little Arc then stays open.
- Little Arc never stays open after its page has gone, and a moved page belongs to its window alone: closing that window closes it as any of its tabs.

## Acceptance checks

1. With the setting at its default, open a browser window, then run `open https://example.com` in Terminal: a small floating window shows example.com with the host and Open in Bow in its title bar, and the browser window has no new tab.
2. In Little Arc, press Ctrl+2 with a second Space of the same profile: the browser window shows that Space with example.com selected, Little Arc is gone, and the page did not reload.
3. Open another link, type in a page field that asks before leaving, close Little Arc and choose Stay: Little Arc stays with the text; close it again and choose Leave: it closes.
4. Turn the setting off (`defaults write` the key to false), open a link: it opens as a new tab in the browser window.
5. Run `make e2e E2E=little-arc`: it prints `PASS little-arc: window=mini main_unchanged=true promote=work`, `PASS little-arc.close: stay=kept leave=closed main_unchanged=true` and `PASS little-arc.off: little_arc_windows=0 opened_in_window=true tabs=1->2`.

## Out of scope

- Making Bow the default browser (a separate item).
- A settings window for the setting, a global hotkey that opens an empty Little Arc, Option+Command+click and routing rules whose destination is Little Arc (see `spec/link-routing.md`).
- Choosing Little Arc's profile from its toolbar, its downloads tray, auto archiving Little Arc windows and remembering a window size the person chose.
