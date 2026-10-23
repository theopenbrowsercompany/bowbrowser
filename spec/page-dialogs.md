# Page dialogs

## Summary

A page's `alert()`, `confirm()` and `prompt()` belong to the tab that asked, as they do in Chrome and Arc.
They come up as a sheet on the window showing that tab and never freeze the rest of Bow.

## Behavior

- A dialog from the tab a window shows comes up at once as a sheet on that window, and the page waits for the answer.
  - The sheet's title names who asks: "bow.test says" for a web page (with the port when it is not the usual one), and "This page says" when there is no site to name (a file, `data:` or no origin).
  - The page's message is the sheet's text.
  - An alert has OK; a confirm has OK and Cancel; a prompt has a text field holding the page's starting text, OK and Cancel.
  - OK gives a confirm `true` and a prompt the typed text; Cancel (or Escape) gives a confirm `false` and a prompt `null`.
- Bow follows Chromium's policy for tabs the person is not looking at (the Chromium blog post "Chromium policy on JavaScript dialogs" and Chromium's tab modal dialog manager):
  - an alert from a tab the window does not show returns at once, so its page goes on, and comes up when the person shows that tab;
  - a confirm or prompt from a tab the window does not show returns at once as cancelled (`false`, `null`) and never comes up.
- Switching to another tab while a dialog is up takes its sheet down: an alert counts as answered and comes up again when its tab is shown again; a confirm or prompt is cancelled.
- A new dialog from a tab replaces the tab's earlier one, which is cancelled.
- A tab that starts going to another page, closes, or is in a window that closes has its dialog taken down and cancelled; quitting cancels every dialog, so a dialog never holds up a close or a quit.
- A tab whose alert waits for it to be shown is not unloaded to save memory (see unload.md), so the alert is never lost unseen.
- A sized popup window (a `window.open` with a size, which stays a window of its own) asks on its own window, as a sheet there, with the same title, buttons and answers as a tab's dialog.
- A popup window that closes (the page closes it, or a quit asks every page to close) takes its sheet down first, answered as cancelled, so its window closes and the sheet never holds up a quit.
- The "leave this site?" prompt is not one of these dialogs: the tab asks it itself, as before (see quit.md and tabs.md).
- No page dialog is ever an app modal panel: other tabs keep running and other windows stay usable.

## Edge cases

- Two tabs ask at once: the shown tab's dialog comes up, the other follows the rules for tabs not shown.
- A dialog from a tab in a Space that is not on screen counts as from a tab the window does not show.
- A tab in another window that shows it counts as shown in that window and asks there.
- While a sheet is up on a window, that window waits for it (as any macOS sheet does); other windows stay usable.

## Acceptance checks

1. Show a page and have it call `alert("Hello")`: a sheet titled "bow.test says" with "Hello" and OK comes up on its window; pressing OK lets the page go on.
2. Have the shown page call `confirm()` twice: OK returns `true`, Cancel returns `false`.
3. Have the shown page call `prompt("Name?", "seed")`: the field holds "seed"; typing "typed" and pressing OK returns "typed"; Cancel returns `null`.
4. Have a background tab call `alert()`: it returns at once and nothing shows; showing that tab brings the alert up.
5. Have a background tab call `confirm()` and `prompt()`: they return `false` and `null` at once, and showing the tab shows nothing.
6. With a confirm up, switch tabs: the page gets `false` and the sheet goes; with an alert up, switch away and back: the alert comes back.
7. With a dialog up, go to another address, close the tab, or close the window: each happens at once and the sheet goes.
8. Open a sized popup window that asks an alert, two confirms and a prompt: each comes up as a sheet on the popup's window, and the page gets `undefined`, `true` for OK, `false` for Cancel and the typed text; with its alert up, quitting closes the popup and its sheet.
9. Run `make e2e E2E=dialogs`: `PASS dialogs.alert`, `PASS dialogs.confirm`, `PASS dialogs.prompt`, `PASS dialogs.background_alert`, `PASS dialogs.background_confirm`, `PASS dialogs.switch_away`, `PASS dialogs.navigate`, `PASS dialogs.close_tab`, `PASS dialogs.close_window`, `PASS dialogs.popup_window`, `PASS dialogs.popup_sheet.alert`, `PASS dialogs.popup_sheet.confirm`, `PASS dialogs.popup_sheet.prompt`, `PASS dialogs.popup_sheet.answers` and `PASS dialogs.popup_sheet_quit`.

## Out of scope

- A badge on a tab whose alert waits (Chrome marks the tab); a later change can add it.
- Chrome's rule that a tab in a window that is not frontmost counts as a background tab: Bow counts the tab each window shows as shown.
- HTTP sign in and other panels, which will reuse the same sheet pattern.
- The leave prompt (see quit.md).
