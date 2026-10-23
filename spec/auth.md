# Sign in and certificate errors

## Summary

A site that asks for a user name and password gets a native sign in sheet on the window showing its tab, and a page whose certificate cannot be verified is replaced by a plain error page with a way back, never loaded silently.
This is what intranet sites, routers and broken certificates meet, as they do in Chrome and Arc.

## Behavior

- A site (or a proxy) asking for a user name and password brings up a sheet on the window showing the tab that asked.
  - Its title is "Sign in".
  - Its text names who asks: the site's host (with the port when it is not the usual one) and the area it named, in quotes, for example "auth.example asks for a user name and password for “Staff”."; a proxy is named with its port.
  - A site reached over plain HTTP adds "Your connection to this site is not private.", since the password would travel unencrypted.
  - It has an empty user name field, a password field that hides what is typed, Sign In (the default button, which Return presses) and Cancel (which Escape presses).
- Sign In sends what was typed and the page goes on loading; a wrong password makes the site ask again, which brings up a new, empty sheet.
- Cancel tells the site no credentials are coming, so the page shows the site's own "sign in required" page.
- Bow never saves or fills a password from the sheet.
- The sheet follows the rules of the page dialogs (see page-dialogs.md) for tabs the person is not looking at:
  - a tab the window does not show waits, unanswered, and its sheet comes up when the person shows the tab;
  - switching away from a tab whose sheet is up takes the sheet down, and switching back brings it up again, still unanswered.
- A tab that goes to another address, crashes or closes with a sheet up or waiting, a window that closes, and quitting each cancel the request, so a sign in never holds up a close or a quit.
  Every request is answered exactly once.
- A page in a popup panel (a sign in window a site opened) that asks gets the same sheet on the panel, never on the window under it.
  Closing the panel, closing the tab that opened it, closing its window and quitting each cancel the request once, and the panel goes.
- The sign in sheet and the page dialogs share one way of showing a sheet, so one waits for the other on the same window or panel.
- A page whose certificate fails to verify does not load: the tab shows a page over its content titled "This connection is not secure", saying in plain words that Bow could not confirm this is the real site (by its host), what is wrong with the certificate (for example that it is not from an authority this Mac trusts), and what could happen, with the engine's error name under it (for example `NET::ERR_CERT_AUTHORITY_INVALID`).
- The error page's one action is Go back, the primary pill: it goes back to the page before in the tab's history, or, in a tab with no page before, closes the tab as Cmd+W does (the Space then shows its next tab, or the start screen when it has none).
- The error page offers no way on to the site, and nothing loads the site silently: the site never sees a request.
- The error page goes when its tab goes to another address, reloads, crashes or closes; a tab that failed while the person looked elsewhere shows it when shown.
- While the shown tab shows the error page, the URL field shows the address that failed with a crossed lock in the brand's deep red, never the address of the page before; the tab's title stays as it was.
- The error page takes the keyboard as it comes up, as Chrome focuses its warning page, so Return (or Enter) presses Go back.
  It never takes the keyboard from a field the person is typing in: Return in the command bar still goes to the typed address.
  When the page goes, the keyboard goes back to the tab's page.
- In split view the error page covers only the pane whose tab failed, follows that pane as the panes resize, and leaves the other panes usable; over the focused pane it keeps the pane's focus outline.

## Edge cases

- Two tabs ask at once: the shown tab's sheet comes up, the other waits for its tab.
- A popup panel whose page already shows a dialog when it asks to sign in: the sign in sheet waits for the dialog to end, then comes up on the panel.
- Two panes both fail their certificate: each shows its own error page, and only the focused one takes the keyboard.
- A pane whose tab closes under its error page takes the error page with it; the remaining pane shows its own page.
- A tab in a Space that is not on screen counts as a tab the window does not show.
- While another sheet is up on the window (a page dialog or a leave prompt), the sign in sheet waits for it to end, then comes up.
- A site naming a very long or multi-line area is quoted on one line, cut to 80 characters with an ellipsis.
- An error the engine reports for a load the tab has already left (the person went elsewhere while it was asked) shows nothing.
- A certificate error the engine has no plain words for says its certificate could not be verified, with its error number.

## Acceptance checks

1. Load a page answering 401 with a Basic challenge: the sheet titled "Sign in" names the host and area, with empty fields, Sign In as the default and Cancel; Sign In with the right password loads the page.
2. Load it again in a new area and press Cancel: the site's 401 page shows.
3. Sign in with a wrong password: a new sheet comes up; the right password then loads the page.
4. With the sheet up, close the tab, go to another address, or close the window: the request is cancelled once and no sheet or request is left.
5. Load the page in a background tab: no sheet shows until the tab is shown; switching away takes it down and switching back brings it again.
6. Load a page with a self-signed certificate after another page: the error page shows the host, the reason and `NET::ERR_CERT_AUTHORITY_INVALID` with only Go back; Go back returns to the page before, and the site saw no request.
7. Open a new tab straight on that page: Go back closes the tab.
8. With the error page up, the URL field shows `badcert.bow.test` with the crossed lock; Go back brings back the page before's address with the usual lock.
9. With the error page up, Return goes back; with the command bar open over it, Return goes to the typed address.
10. Show two tabs side by side and fail the second one's load: only the second pane is covered, the cover follows a divider drag, the first pane takes focus and runs its page, and closing the failed tab takes the cover away.
11. A popup panel page asks to sign in: the sheet is on the panel, Sign In loads the page there; with the sheet up, closing the panel, its opener tab or its window cancels the request once.
12. Run `make e2e E2E=auth`: `PASS auth: prompted=true ...`, `PASS auth.cancel`, `PASS auth.retry`, `PASS auth.close`, `PASS auth.navigate`, `PASS auth.background`, `PASS auth.close_window`, `PASS cert.page`, `PASS cert.no_history`, `PASS cert.address`, `PASS cert.return`, `PASS cert.split`, `PASS auth.panel`, `PASS auth.panel_close`, `PASS auth.panel_opener_close` and `PASS auth.panel_window_close`.

## Out of scope

- A way past a certificate error behind a details link: it waits until the engine can say whether a site requires HTTPS (HSTS), which sites may never be bypassed (see engine-hooks.md).
- Saved passwords and filling the sheet from them.
- A badge on a tab whose sign in waits.
