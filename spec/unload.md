# Unloading tabs

## Summary

Bow closes the page behind tabs you have not used for a while, or when the Mac runs short of memory, so many open tabs stay cheap.
An unloaded tab stays in the sidebar and loads again when you open it.

## Behavior

- A tab that has not been used for a while is unloaded.
  How long "a while" is depends on memory pressure: it is longest when memory is fine and shorter when the system is under pressure.
- When more tabs are loaded than memory pressure allows, the least recently used tabs are unloaded first until the limit is met.
- Under critical memory pressure every tab that may be unloaded is unloaded, regardless of how recently it was used.
- Pinned tabs and Favorites are unloaded after a longer idle time than other tabs, except under critical memory pressure.
- These tabs are never unloaded, whatever the pressure: a tab playing sound, a tab using the camera or microphone, and a tab visible in a window.
- An unloaded tab keeps its address, title, icon and a snapshot placeholder.
  Opening it loads the page again from its address.
- Unloading a tab loses its back and forward history, and the page's own state (scroll position, form text) is not kept.
  This stays so until a later phase restores navigation history.
- The decision depends only on the tabs, the clock and the memory pressure, so the same inputs always give the same tabs in the same order.
- The idle times and loaded tab limits are settings, not fixed numbers, and are tuned from measurements.

- Unloading a page lets its beforeunload handler run but never shows a prompt: a page that would ask to stay is left loaded.
- A tab that is closing for good is never unloaded instead: not after its page closed itself, and not while the app quits.
  Closing a tab whose unload is still under way turns it into a close: the unload reports that it did not happen, and the tab is closed by the app.

## Edge cases

- A tab that is already unloaded is never chosen again.
- When trimming to the loaded tab limit, pinned tabs and Favorites go last.
- Tabs that are exempt still count toward the loaded tab limit, so other tabs may be unloaded to make room for them.
- If every loaded tab is exempt, nothing is unloaded, even under critical memory pressure.
- A tab whose last use is in the future (clock change) counts as just used, so it is not unloaded for being idle (critical memory pressure still unloads it).

## Acceptance checks

1. Normal memory, two tabs idle for 5 minutes: both stay loaded.
2. Normal memory, a tab idle for 31 minutes: it is unloaded.
3. Same tab idle for 31 minutes but pinned: it stays loaded; at 91 minutes it is unloaded.
4. Warning pressure, a tab idle for 11 minutes: it is unloaded.
5. Critical pressure, one visible tab and one recently used background tab: only the background tab is unloaded.
6. A background tab playing audio, or using the microphone, idle for hours: it stays loaded.
7. Fourteen recently used loaded tabs at normal pressure: the two least recently used are unloaded.

These run as unit tests today (`UnloadPolicyTests`).

8. Run `make e2e`: the `engine.unload` check unloads a tab through the engine, then closes a tab whose slow beforeunload keeps its unload pending, and prints `PASS engine.unload: unloaded=true closed=true last=unloaded taken-over-unload=false close=true close-last=closed close-reason=app`.
9. Run `make e2e`: `PASS tabs.unload-reload: row=kept loaded=again url=same` shows an unloaded tab keeping its row in the window and loading again at its address when chosen, and `PASS tabs.unload-stay` shows a page that would ask to stay left loaded with no prompt.

## Out of scope

- Reading memory pressure from the engine, the placeholder snapshot and sidebar display: they need the app and the measurements, and are not built yet.
  Reopening the page works: a window keeps an unloaded tab's row and loads it again when chosen.
- The idle times and limits shown here are placeholders until those measurements arrive.
- Restoring back and forward history after unloading.
