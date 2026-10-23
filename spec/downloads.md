# Downloads

## Summary

Files a page offers for download are saved to disk and listed in a downloads window, where the person can follow their progress and pause, resume, cancel or clear each one.
Each profile keeps its own downloads, and the window shows every profile's downloads together.

## Behavior

- Clicking a download link (or opening any address the page serves as a file) starts a download at once, with no prompt.
- By default the file is saved straight into the person's Downloads folder, under the name the site suggests.
- When the folder already has a file of that name, or another download is still writing to it, the new file is numbered: `a.pdf` becomes `a (1).pdf`, then `a (2).pdf`; an archive keeps its full extension (`site.tar.gz` becomes `site (1).tar.gz`).
- Names the site suggests are made safe first: slashes and colons become underscores, control characters are dropped, a leading dot is dropped so the file is never hidden, and an empty name becomes `download`.
- The downloads window (Window > Downloads, Option+Command+L) lists every download, newest first, with its file name, a progress bar and a status line: the bytes received so far and the total when known, or Paused, Complete, Cancelled, Failed or Status unknown.
- Each running download has Pause and Cancel buttons; a paused download has Resume and Cancel; a failed download has Resume and Clear; a complete or cancelled download, or one whose status is unknown, has Clear.
- Pause stops receiving bytes and keeps what was received; Resume continues where it stopped.
- Cancel stops the download for good and deletes its partial file.
- Clear takes a finished download out of the list and leaves the file on disk.
- A downloads button sits at the left of the sidebar footer (a Soft downloads symbol, 17 points, labelled "Downloads"): clicking it shows the downloads window, bringing it forward when it is already open rather than opening a second one.
  While any download is running the symbol is the filled one; paused and finished downloads do not count.
- The window's "Ask where to save each file" checkbox turns on a save panel for every new download, opened on the Downloads folder with the numbered name filled in; choosing Cancel in the panel cancels the download.

## Edge cases

- A download whose size the server does not send shows an animated progress bar and only the bytes received.
- Downloads started by a popup belong to the profile of the tab that opened it.
- Two profiles can each have a download with the same internal number; the list keeps them apart.
- A finished download never changes state again, even if a late progress report arrives.
- The list lasts for the session: after a restart it starts empty, and files already saved stay on disk.
- Downloads survive closing the tab that started them.
  The tab leaves the sidebar and the window at once, as any closed tab does, but the engine keeps its page alive out of sight until every download it started has completed, been cancelled, failed or been cleared; then the page closes for good.
  While it runs, such a download keeps its row, its controls and its name, and the same file downloaded again is numbered.
- Such a kept page has run its unload handlers but still runs: its timers and network go on, slowed as in any hidden page, and it is muted.
  Nothing it asks for reaches the person: popups and new windows are blocked, alerts and other page dialogs are dismissed unseen, permission requests are denied, and file choosers and context menus do not open.
  It cannot start a new download either, so it cannot keep itself alive.
- Closing the last window while such a page is kept does not quit the app, since quitting would cancel its downloads: the app stays open with no window until the last of them ends, then quits, unless a window has opened meanwhile.
- Quitting does not wait for downloads: the closed tabs kept for their downloads close with the rest of the app, which cancels those downloads, and quitting stays as fast as without them.
  Staying on a page at its leave prompt cancels the quit and keeps them running.
- A download whose page closes anyway (a popup in its own window closing, or the engine stopping) can no longer be reported by the engine, and the engine would cancel it with the page, deleting its partial file.
  Its row still updates: the list follows the download's file on disk instead, so within a moment it reads Cancelled, it can be cleared, and its name is free for the next download of the file.
- After its page closes, the list follows the download's file on disk instead of the engine: the bytes received follow the file's size, a file the download wrote that reaches its known size and stays there for two reads is Complete, and a file that disappears, or a running download's file that never appears within 2 seconds, is Cancelled.
  A file that was already there (one the person chose to replace in the save panel) counts only once the download changes it.
  A download that failed before its first byte stays as it was, since it can still resume; a paused one is cancelled like a running one.
  When a download ends while its save panel is still open, the panel closes.
  Pause and Cancel show at once; Resume shows the download running again, and if its file does not grow it later reads "Status unknown".
  A file that stops changing for 15 seconds without finishing reads "Status unknown" (it may be stalled, failed, or finished at an unknown size); such a row can be cleared, which cancels the download, and its name is no longer held for it until the file grows again.

## Acceptance checks

1. With a page that links to `a.pdf`, click the link: `a.pdf` appears in the Downloads folder and the downloads window shows it as Complete.
2. Click the same link again: the new file is `a (1).pdf` and the first file is unchanged.
3. Start a large download, open the downloads window and click Pause: the status reads Paused and the byte count stops; click Resume and it grows again; click Cancel and it reads Cancelled with no partial file left.
4. Click Clear on a finished download: the row goes away and the file stays in the Downloads folder.
5. Turn on "Ask where to save each file" and click a download link: a save panel opens on the Downloads folder with the suggested name; Cancel there cancels the download.
6. Start a download in a second tab and close that tab while it is still running (the e2e fixture holds it until the test releases it): the tab goes at once, the download keeps running (the same file downloaded meanwhile is numbered) and completes with every byte saved, Clear removes the row, and the hidden page closes once the download has ended.
   `make e2e E2E=downloads.tab-closed` prints `PASS downloads.tab-closed: state=complete row=updated closed-while=inProgress`.
7. Close a tab whose page, once closed, keeps trying to open a popup, show an alert and start another download: no window, popup or dialog appears and no new download is listed, while its first download keeps running.
   `make e2e E2E=downloads.parked-page` prints `PASS downloads.parked-popup`, `PASS downloads.parked-dialog` and `PASS downloads.parked-download`.
8. Close the window whose tab is downloading: the download keeps running and the engine reports the closed tab as kept until the download is cancelled.
   `make e2e E2E=downloads.window-closed` prints `PASS downloads.window-closed: kept before=false after-close=true download=inProgress released=true`.
   With the downloads window hidden, `make e2e E2E=downloads.footer-button` clicks the footer button and prints `PASS downloads.footer-button` (one window after two clicks) and `PASS downloads.footer-activity` (the symbol is filled while a download runs).
9. `make e2e E2E=downloads` prints `PASS downloads: file=a.pdf state=complete`, saving into the run's own folder rather than the real Downloads folder.

## Out of scope

- Choosing a different default folder from a settings window (the setting exists but has no interface yet).
- Opening a file or showing it in Finder from the list, and a downloads popover in the browser window.
- Keeping the list across restarts, and Safe Browsing or dangerous file warnings.
