# Little Arc

## Summary

Little Arc is a small floating window for links clicked in other apps (Slack, Mail, a chat), so a quick look does not add a tab to the person's Spaces.
The person reads the page and closes the window, or moves the page into a Space with one key, where it keeps running as it was.

## Behavior

### Opening

- The setting "Links from other apps open in Little Arc" is on unless the person turns it off, as in Arc.
  It is stored as `littleArc.opensExternalLinks` in the app's settings; there is no settings window for it yet.
- While it is on, each link another app sends opens in a new Little Arc window of its own, also when no browser window is open, as in Arc.
  Links Bow kept while starting open the same way, in order, once the first window is open.
- The page opens in the profile of the Space on screen in the browser window links go to (the main window, else the last one shown), the same profile a link opens in without Little Arc.
  With no browser window open it opens in the profile of the Space shown last (the Space on screen in the window that closed last, else in Bow's own sidebar), as Arc uses the last used Space.
- Little Arc is a floating panel that stays above other windows.
  It opens centered on the display under the pointer (the app the link was clicked in), else the display of the key window, at about 900 by 660 points, smaller on a small display, and on the macOS Space in use, also over a full screen app.
  It comes forward and takes the keyboard, so the person can read and scroll at once.
- The browser window is left as it was: no tab opens in it, and its Space and shown tab stay the same.
- Little Arc has a compact toolbar in its title bar: the page's address (its host), a Move menu and an Open in Bow button.
- With the setting off, a link opens as it did before Little Arc: a new tab in the browser window's Space on screen, or a new window (see `spec/link-routing.md`).

### The page in Little Arc

- The page's alerts, confirms and prompts come up as sheets on Little Arc, under the same rules as a tab's (`spec/page-dialogs.md`).
  A move waits until the dialog is answered.
- A permission request (camera, microphone, location and the others) shows the same prompt as in a browser window, anchored to the top of Little Arc's page, and the answer is remembered in the page's profile as in a browser window (`spec/permissions.md`).
- While Little Arc is the key window, the main menu's page commands act on its page, never on the browser window behind it: Reload Page (Cmd+R), Stop (Cmd+.), Back (Cmd+[) and Forward (Cmd+]).
- Open Location (Cmd+L) makes the toolbar's address editable, showing the page's full address selected; Return loads what was typed (an address or a search) in Little Arc's page, and Escape puts the host back.
- Find (Cmd+F), Find Next and Find Previous are disabled while Little Arc is key: Arc's documentation gives Little Arc no find bar, and the browser window behind must not be searched instead.

### Moving the page into a Space

- Open in Bow (the toolbar button, or Cmd+O while Little Arc is in front) moves the page into the Space the browser window shows.
- The Move menu lists every Space of the browser window in sidebar order, the Space on screen checked.
  Choosing one, or pressing Ctrl and its number (Ctrl+1 to Ctrl+9, the numbers Bow uses for Spaces) while Little Arc is in front, moves the page into that Space.
- A move shows the chosen Space in the browser window, adds the page as a new tab in its Today section (after the selected Today tab, as a link opens), selects it, closes Little Arc and brings the window forward.
- The page is moved, never reloaded: its scroll position, form text, logins and media keep going.
- With no browser window open, Open in Bow opens a new browser window on Bow's sidebar showing the Space shown last when it has the page's profile, else the first Space of that profile, and moves the page there as above, without opening the home page beside it.
  With no Space of the page's profile, Open in Bow beeps and the page stays.
- A move that switched the browser window's Space and then could not add the page there switches the window back to the Space it showed, and the page stays in Little Arc as it was.
- A Space of another profile is listed but disabled: a live page cannot change profile.
  Open in Bow does nothing (a beep) while the Space on screen has another profile.

### Closing

- Closing Little Arc (its close button, Cmd+W or Close Window) closes its page; nothing is kept or archived.
- A page that asks before leaving asks first: Stay keeps Little Arc and its page as they were, Leave closes both.
- Little Arc also closes when its page closes itself and when Bow quits.
  A dialog or permission prompt up at that moment is answered as cancelled or dismissed and goes with it.
- Closing the last browser window while Little Arc is open does not quit Bow: Little Arc counts as a window, as in Arc.

## Edge cases

- Several links open several Little Arc windows, each on its own page.
- A move while the page's leave prompt is open (a close is under way) does nothing; the person answers the prompt first.
- A move when the browser window has closed meanwhile goes to the window links now go to; with no window open, Open in Bow opens one (see above) and the Move menu lists no Space.
- The browser window switching Spaces while Little Arc is open changes where Open in Bow moves the page: it always follows the Space on screen at the moment of the move.
- Quitting with Little Arc open closes its page with every other page; a page that asks before leaving can cancel the quit, as any page can, and Little Arc then stays open.
- Little Arc never stays open after its page has gone, and a moved page belongs to its window alone: closing that window closes it as any of its tabs.

## Acceptance checks

1. With the setting at its default, open a browser window, then run `open https://example.com` in Terminal: a small floating window shows example.com with the host and Open in Bow in its title bar, and the browser window has no new tab.
2. In Little Arc, press Ctrl+2 with a second Space of the same profile: the browser window shows that Space with example.com selected, Little Arc is gone, and the page did not reload.
3. Open another link, type in a page field that asks before leaving, close Little Arc and choose Stay: Little Arc stays with the text; close it again and choose Leave: it closes.
4. Turn the setting off (`defaults write` the key to false), open a link: it opens as a new tab in the browser window.
5. Run `make e2e E2E='little-arc*'`: it prints `PASS little-arc: window=mini main_unchanged=true promote=work`, `PASS little-arc.close: stay=kept leave=closed main_unchanged=true`, `PASS little-arc.off: little_arc_windows=0 opened_in_window=true tabs=1->2`, `PASS little-arc.no_window: little_arc=opened open_in_bow=window`, `PASS little-arc.dialog: dialog=sheet answered=1`, `PASS little-arc.permission: prompt=shown allow=granted`, `PASS little-arc.menu: reload=panel main_reloaded=false address=focused find=disabled`, `PASS little-arc.last_window: app=stay little_arc=kept` and `PASS little-arc.adopt_fail: space=Home little_arc=kept main_unchanged=true`.

## Out of scope

- Making Bow the default browser (a separate item).
- A settings window for the setting, a global hotkey that opens an empty Little Arc and Option+Command+click.
  Routing rules whose destination is Little Arc are in `spec/link-routing.md`.
- Choosing Little Arc's profile from its toolbar, its downloads tray, auto archiving Little Arc windows and remembering a window size the person chose.
