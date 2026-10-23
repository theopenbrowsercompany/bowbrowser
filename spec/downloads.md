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
- The window's "Ask where to save each file" checkbox turns on a save panel for every new download, opened on the Downloads folder with the numbered name filled in; choosing Cancel in the panel cancels the download.

## Edge cases

- A download whose size the server does not send shows an animated progress bar and only the bytes received.
- Downloads started by a popup belong to the profile of the tab that opened it.
- Two profiles can each have a download with the same internal number; the list keeps them apart.
- A finished download never changes state again, even if a late progress report arrives.
- The list lasts for the session: after a restart it starts empty, and files already saved stay on disk.
- Closing the tab or popup that started a download currently cancels the download (the engine stops every request of a closed tab), and its partial file is deleted.
  Its row still updates: within a moment it reads Cancelled, it can be cleared, and its name is free for the next download of the file.
  Keeping such downloads running after their tab closes is planned.
- After that tab closes, the list follows the download's file on disk instead of the engine: the bytes received follow the file's size, a file that reaches its known size is Complete, and a file that disappears, or never appears within 2 seconds, is Cancelled.
  Pause and Cancel show at once; Resume shows the download running again, and if its file does not grow it later reads "Status unknown".
  A file that stops changing for 15 seconds without finishing reads "Status unknown" (it may be stalled, failed, or finished at an unknown size); such a row can be cleared, which cancels the download, and its name is no longer held for it.

## Acceptance checks

1. With a page that links to `a.pdf`, click the link: `a.pdf` appears in the Downloads folder and the downloads window shows it as Complete.
2. Click the same link again: the new file is `a (1).pdf` and the first file is unchanged.
3. Start a large download, open the downloads window and click Pause: the status reads Paused and the byte count stops; click Resume and it grows again; click Cancel and it reads Cancelled with no partial file left.
4. Click Clear on a finished download: the row goes away and the file stays in the Downloads folder.
5. Turn on "Ask where to save each file" and click a download link: a save panel opens on the Downloads folder with the suggested name; Cancel there cancels the download.
6. Start a slow download in a second tab and close that tab mid download: the row reads Cancelled with no file left, Clear removes it, and downloading the same file again keeps its name.
   `make e2e E2E=downloads.tab-closed` prints `PASS downloads.tab-closed: state=cancelled row=updated`.
7. `make e2e E2E=downloads` prints `PASS downloads: file=a.pdf state=complete`, saving into the run's own folder rather than the real Downloads folder.

## Out of scope

- Choosing a different default folder from a settings window (the setting exists but has no interface yet).
- Opening a file or showing it in Finder from the list, and a downloads button or popover in the browser window.
- Keeping the list across restarts, and Safe Browsing or dangerous file warnings.
