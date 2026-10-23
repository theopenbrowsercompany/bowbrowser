# Unloading tabs

## Summary

Bow closes the page behind tabs you have not used for a while, or when the Mac runs short of memory, so many open tabs stay cheap.
An unloaded tab stays in the sidebar and loads again when you open it.

## Behavior

- A tab that has not been used for a while is unloaded.
  How long "a while" is depends on memory pressure: it is longest when memory is fine and shorter when the system is under pressure.
- When more tabs are loaded than memory pressure allows, the least recently used tabs are unloaded first until the limit is met.
  When memory is fine there is no such limit: only idle time unloads.
- Under critical memory pressure every tab that may be unloaded is unloaded, regardless of how recently it was used.
- Pinned tabs and Favorites are unloaded after a longer idle time than other tabs, except under critical memory pressure.
- These tabs are never unloaded, whatever the pressure: a tab playing sound or that stopped playing less than 30 seconds ago, a tab using the camera or microphone, and a tab visible in a window.
- An unloaded tab keeps its address, title and icon.
  Opening it loads the page again from its address, and until that page has loaded (or failed to) the page area shows a placeholder: a white card with the tab's icon, title and site, centred.
  The placeholder is not a picture of the page: the page view draws blank when the app draws it, a hidden tab produces no frames to capture, and capturing the window from the system needs the Screen Recording permission.
  It shows only when the tab is the one page shown; a tab loading again in one of several panes shows its page as it loads.
- Unloading a tab loses its back and forward history, and the page's own state (scroll position, form text) is not kept.
  This stays so until a later phase restores navigation history.
- The decision depends only on the tabs, the clock and the memory pressure, so the same inputs always give the same tabs in the same order.
- The idle times and loaded tab limits are settings, not fixed numbers, and are tuned from measurements.

## Numbers and their basis

Measured on a quiet machine in the hidden tab spike (S3): a silent hidden tab under Chromium's default background throttling costs about 0.02 percent of a core and next to no wakeups (29 of them about 0.7 percent of a core together), and reaches its cheapest state about a minute after it is hidden.
What a hidden tab costs is memory: about 31 MB for a light page, more for real ones, so about 900 MB for 29.
A hidden tab playing sound is not throttled at all (about 4.5 percent of a core each, muted or not), and Chromium keeps a page unthrottled for 30 seconds after its sound stops.

| Setting | Normal | Warning | Critical | Basis |
| --- | --- | --- | --- | --- |
| Idle time before unloading | 60 minutes | 10 minutes | none | Normal: judged, since CPU gives no reason to unload sooner and memory pressure covers memory. Warning and critical: judged, kept from the first version. |
| Loaded tab limit | none | 6 | 1 | Normal: from the measurements (a hidden tab costs memory, not CPU, so memory pressure decides). Warning and critical: judged. |
| Pinned tabs and Favorites | idle time times 3 | idle time times 3 | as other tabs | Judged. |
| Recently audible | 30 seconds | 30 seconds | 30 seconds | Measured: Chromium's own unthrottled window after sound stops. |

- Unloading relies on Chromium's default background throttling to keep the tabs it leaves loaded cheap: the shipping app passes none of the switches that turn that throttling off (only e2e runs do).
- Telling a hidden page it is hidden, a lower frame rate and freezing hidden pages measured no gain worth making a default, so Bow does none of them.

- Unloading a page lets its beforeunload handler run but never shows a prompt: a page that would ask to stay is left loaded.
- A tab that is closing for good is never unloaded instead: not after its page closed itself, and not while the app quits.
  Closing a tab whose unload is still under way turns it into a close: the unload reports that it did not happen, and the tab is closed by the app.

## App wiring

- Unloading is on by default, as Chrome's Memory Saver and Arc's tab unloading are, behind one setting; with it off, nothing is ever unloaded, not even under critical memory pressure.
  E2e runs turn it off before the app starts, and the tests that need it turn it on.
- While it is on, Bow looks for idle tabs about once a minute, across every window and every Space, and at once whenever macOS reports memory pressure.
- Under warning or critical memory pressure, as macOS reports it, the shorter idle times and lower loaded tab limits apply, and critical pressure unloads every tab that may be unloaded.
- Never unloaded, however long idle and whatever the pressure:
  - the tab a window shows;
  - a tab mid navigation, still loading its page;
  - any tab of a profile with a download under way, since destroying the page that started it would cancel it;
  - a tab using the camera or microphone;
  - a pinned tab or Favorite showing a page other than its saved address, since loading it again would go back to that address and lose the page it was on;
  - a tab playing sound, or that stopped less than 30 seconds ago, as the page's sound signal reports it (see Page signals);
  - every tab of a window that is closing or showing a sheet (a leave prompt or a page's dialog), and a tab whose page alert waits for the tab to be shown (see page-dialogs.md), so a dialog never vanishes unseen; the next look tries again.
- Never unloaded at normal or warning pressure, neither for being idle nor to meet the loaded tab limit: a tab with an edited form, until it goes to another page (a new document in its main frame).
  A form counts as edited once the page reports an edit (see Page signals), or once a key that enters or edits text in one of its fields reached it through the app (Command-V, Command-X and Command-Z included).
  So form text with no leave prompt to guard it is not lost, however it arrived.
  Under critical pressure such a tab is unloaded like any other, as Chrome's discarding does: the system may end the page's process itself when memory runs out, and freeing memory then outweighs the input.
  It still counts toward the loaded tab limit.
- Pinned tabs and Favorites are spared longer than other tabs.
- The idle times, loaded tab limits and how often Bow looks are named in one place, so measurements can tune them without touching the rest.
- An unloaded tab keeps its row, address, title and icon, and loads again from its address when chosen, without its back and forward history.
  This holds for a tab unloaded while its Space is off screen too: switching back shows its row with its icon and the title its page had.
- Quitting stops unloading at once: no tab is unloaded while the app quits.

## Page signals

The engine (CEF 156) reports neither sound (its audio handler takes the sound over instead of reporting it) nor form input that arrives without a key (paste or cut from the Edit menu, drop, dictation, undo from the menu, autofill, a chosen file), so each page reports them itself.
The helper's render process installs a small script in every frame, main frame and subframes alike, as the frame's JavaScript context is created and before the page's own scripts run, and the script sends each change to the browser as a process message from its frame.
The page cannot call the channel itself: it is handed to the script, never set on the page.

- The script changes nothing the page can see or reach: no prototype, method or global, only event listeners, which a page cannot list.
  The built-ins it uses after installing are taken before the page's scripts run, so a page that replaces them cannot notice it, and no error of its own reaches the page.
  A page that could tell Bow apart from Chrome would let sites single out Bow users in tamper and fingerprint checks (CAPTCHAs, blocks), so whatever cannot be seen this way goes unseen (see Known gaps).
- Sound: a frame plays sound while one of its media elements plays (not paused, not ended) unmuted at a volume above 0.
  The script learns of an element from its media events (play, playing, pause, ended, volume change, emptied) as they pass the frame's window, and from then on follows the element's own events, holding it weakly and letting it go once it stops.
  Sound starting is reported at once; sound stopping only once the frame has been quiet for 2 seconds, so a gap between tracks does not end it.
  The tab is audible while any of its frames is, and its sound stopping starts the 30 second recently audible window.
- Form edit: the first input or change event the browser fires in a frame's document (on a text field, text area, list, check box, file input or editable text, by any means), once per document.
  Events a page fires from its own script do not count, so a page cannot keep itself loaded that way.
- A frame's signals go when its document goes (the frame navigates, even when the engine keeps the same frame for the next document), when the frame leaves the page (removed, or into the back and forward cache), when the main frame commits a new document, and when the page's render process ends.
  A page restored from the back and forward cache reports its edited form again and looks at its sound afresh.

### Known gaps

Each of these would need the script to change something the page can see (wrap a media or Web Audio method), which would let sites fingerprint Bow, so a tab playing sound only these ways is not kept loaded for its sound:

- Sound made only with Web Audio (many games, music tools built on libraries like Tone.js).
- A media element that plays without ever being in the frame's document (an audio object made and played by script), since its media events never pass the window.
- A media element inside a shadow tree, since its media events do not leave the tree (they are not composed).

Paste from the Edit menu is covered by the form edit rule (the browser fires a trusted input event with no key event) and by the key rule for Command-V, but has no end to end test of its own: driving it would swap the person's shared clipboard during the run.
Input from an input method (dictation) goes the same way and is tested end to end.

## Edge cases

- A tab that is already unloaded is never chosen again.
- When trimming to the loaded tab limit, pinned tabs and Favorites go last.
- Tabs that are exempt still count toward the loaded tab limit, so other tabs may be unloaded to make room for them.
- If every loaded tab is exempt, nothing is unloaded, even under critical memory pressure.
- A tab whose last use is in the future (clock change) counts as just used, so it is not unloaded for being idle (critical memory pressure still unloads it).

## Acceptance checks

1. Normal memory, two tabs idle for 5 minutes: both stay loaded.
2. Normal memory, a tab idle for 61 minutes: it is unloaded; at 59 minutes it stays.
3. Same tab idle for 61 minutes but pinned: it stays loaded; at 181 minutes it is unloaded.
4. Warning pressure, a tab idle for 11 minutes: it is unloaded.
5. Critical pressure, one visible tab and one recently used background tab: only the background tab is unloaded.
6. A background tab playing audio, or that stopped 29 seconds ago, or using the microphone, idle for hours: it stays loaded; 30 seconds after its sound stopped it may be unloaded.
7. Thirty recently used loaded tabs at normal pressure: none is unloaded; eight at warning pressure: the two least recently used are unloaded.
   A background tab with an edited form, idle for a day: it stays loaded at normal and warning pressure, is passed over when trimming to the loaded tab limit (while still counting toward it), and is unloaded under critical pressure.
8. The placeholder shows for an unloaded tab shown alone, not in one of several panes, and goes when its page finishes, fails, its render process ends or it closes.

These run as unit tests today (`UnloadPolicyTests`).

9. Run `make e2e`: the `engine.unload` check unloads a tab through the engine, then closes a tab whose slow beforeunload keeps its unload pending, and prints `PASS engine.unload: unloaded=true closed=true last=unloaded taken-over-unload=false close=true close-last=closed close-reason=app`.
10. Run `make e2e`: `PASS tabs.unload-reload: row=kept loaded=again url=same` shows an unloaded tab keeping its row in the window and loading again at its address when chosen, and `PASS tabs.unload-stay` shows a page that would ask to stay left loaded with no prompt.

11. Run `make e2e E2E=unload`: `PASS unload.off` shows nothing unloaded with the setting off, after a day idle and under critical pressure; `PASS unload.policy: live=1 unloaded=3` shows a pass after a day idle unloading every background tab and keeping the shown one, and `PASS unload.reload` choosing an unloaded tab loading it again at its address; `PASS unload.exempt` shows a tab using the camera kept; `PASS unload.pressure` shows critical pressure unloading a recently used background tab; `PASS unload.engine_reload` shows an unloaded row keeping its title and icon; `PASS unload.dialog` shows a pass while a background tab's alert waits for its tab unloading nothing, and the next pass after the alert was shown and answered unloading the tab.
12. Run `make e2e E2E=unload`: `PASS unload.offscreen_space: unloaded=3` shows a today tab and a pinned tab unloaded while their Space is off screen keeping their icon, address and title when you switch back, and `PASS unload.offscreen_reload` choosing each loading it again at that address; `PASS unload.pinned_away: unloaded=1 pinned=live` shows a pinned tab browsed away from its pinned address kept loaded while a background tab unloads; `PASS unload.typed: unloaded=0 tab=live` shows a tab with text typed into its field kept loaded with its text, and `PASS unload.typed_navigated: unloaded=1` shows it unloading once it has gone to another page.
13. Run `make e2e E2E=unload`: `PASS unload: live=1 unloaded=29` shows 30 tabs in one window, one shown, at normal pressure: nothing unloaded 59 minutes on, every background tab 61 minutes on; `PASS unload.audible: within=live quiet=unloaded after=unloaded` shows a tab whose sound stopped 20 seconds ago kept under critical pressure while a quiet tab unloads, and unloaded 31 seconds after; `PASS unload.placeholder: unloaded=1 card="Unload held" page=shown order=card,page` shows an unloaded tab chosen again showing the card with its title while its page loads, then its page.
14. Run `make e2e E2E=unload`: `PASS unload.audible_page: element=live within=live after=unloaded` shows a background tab playing a quiet tone through an audio element kept after a day idle, kept 20 seconds after the sound stopped and unloaded 31 seconds after; `PASS unload.form_dictation: unloaded=0 tab=live edited=true keys=0` shows a tab whose field got text from an input method, with no key event, kept after a day idle with its text.

## Out of scope

- Showing in the sidebar that a tab is unloaded: Arc shows no such marker, so Bow does not either.
- A snapshot of the page as the placeholder (see Behavior for why it is a card).
- A setting in a settings window for unloading is not built yet; it is a stored setting only.
- Restoring back and forward history after unloading.
