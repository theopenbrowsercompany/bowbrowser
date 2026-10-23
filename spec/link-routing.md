# Link routing (Air Traffic Control)

## Summary

Link routing decides where a link opened from outside the browser goes, so work links land in the work Space and personal links never open in a work account.
People set it up once as an ordered list of rules plus a default.

## Behavior

### Receiving links

- Bow declares that it opens http and https links, so the person can choose it as their browser in System Settings.
  Bow never makes itself the default browser on its own.
- Another app hands Bow a link as a "get URL" request (a link clicked in Mail or Slack, `open https://...` in Terminal).
- Only http and https addresses with a host are taken; anything else, or text that is not an address, is ignored.
  Surrounding spaces and newlines are ignored.
- Each request names the app that sent it when the system knows it.
  Bow records that app by its bundle identifier, and a helper process inside an app (for example "Slack Helper" inside Slack) counts as that app.
  A sender that is no app (a command line tool such as `open`) or a request with no sender leaves the link with no source app.
- Every link goes through the routing rules below before anything opens for it.
  With no rules (the starting state) the default is Little Arc, so a link opens in Little Arc while "Links from other apps open in Little Arc" is on (the default) and a Space can give its page a profile, a window being open or not (see `spec/little-arc.md`); otherwise in a new tab of the most recently used window, in the Space on screen there, as Arc does without rules.
- Links that arrive before Bow can open them are kept, in the order they came, and open once the first window is open.
  In practice the engine is ready before the system hands Bow its first link, so links that launch Bow open right away.
- Links that arrive while Bow is quitting are dropped, so quitting never opens a new window; if a page cancels the quit, later links open again.
- When launch refuses to start (the sidebar cannot be opened), kept links and links that arrive while its alert is open are dropped.
- A burst of links opens every one, each in its own tab, in the order they came.
- Links from other apps never open in an e2e or smoke run: they are meant for the person's own Bow.
  The e2e run delivers its own links through a test only path, so the real path stays closed.

### Routing rules

- The routing list is ordered rules plus one default destination, and optionally a "no source" destination.
  The first rule that matches a link decides where it opens; if none matches, a link with no source app goes to the "no source" destination when one is set, and every other link to the default.
  The "no source" destination exists because some apps cannot be identified as senders (apps that hand links to the `open` command, terminal apps), so they still get a place of their own.
- A rule has a URL condition, a source app condition, or both, and a destination.
  A rule with both needs both to hold.
  A rule with neither is not usable and never matches.
- The URL condition is either "contains" (the link's address includes the text) or "matches" (the text is a regular expression found anywhere in the address, so `^` and `$` anchor it).
  Both ignore case.
  An empty text, or an expression that is not valid, makes the rule unusable.
- The source app condition names an app by bundle identifier and ignores case.
  A link whose sender is unknown never matches a rule that names an app, so it can only reach rules with a URL condition alone, or the default.
- A helper process (for example a chat app's web view helper) counts as its parent app, using a mapping supplied by the app.
- A destination is a Space, a profile, Little Arc, or the most recent window.
  Spaces and profiles are named by ID.
- Order is the only tie breaker.
  A narrow rule must sit above a broader one, or the broader rule hides it.
  The editor can list rules that are hidden by an earlier rule, and rules that are unusable, with the reason.
- The saved list carries a version and lives in one file beside the sidebar file, written whole after every change so a crash never leaves half a list.
  A list saved by a newer version of the app is refused rather than partly read: the file is left untouched and never saved over, links follow the starting rules, and the editor says that changes last only until Bow quits.
  A file that cannot be read is moved aside under a new name, untouched, and routing starts over from the starting rules.

### Where a routed link opens

- A Space destination opens the link in a new tab of that Space: the browser window that shows the Space switches to it (sliding as the Space switcher does) and the tab is created there, so the page loads in the Space's profile from its very first request and never moves.
  The window chosen is the most recently used one; with no window open, a new window opens with that Space on screen.
- A profile destination opens the link in a Space of that profile: the Space on screen when it shows that profile, else the first such Space in sidebar order.
- A Little Arc destination named by a rule opens Little Arc whatever the "Links from other apps open in Little Arc" setting says, because the person asked for it in that rule; the default being Little Arc follows the setting.
  Little Arc needs a Space for its page's profile: the Space on screen in the browser window, or with none open the Space shown last; only with neither does the link open in a browser window.
- The most recent window destination opens a new tab in the Space on screen of the most recently used window.
- A rule (or the "no source" destination) naming a Space or profile that no longer exists, because it was deleted, gives way to the default; a default that no longer exists gives way to the most recent window, so a link always opens somewhere.
- Links that arrive while the rule editor is open follow the rules as they are saved at that moment.

### The rule editor

- Bow > Air Traffic Control… opens the rule editor, a standard window.
  Arc keeps Air Traffic Control in its settings; Bow has no settings window yet, so it sits in the app menu, where settings go on macOS.
- It lists the rules in order, one row each: the address condition ("is any address", "contains" or "matches") and its text, the source app's bundle identifier (empty for any app), and where the link opens.
- Add Rule adds a rule at the end; Remove deletes the selected rule; Move Up and Move Down move the selected rule, which matters because the first match wins.
- Below the list are where links open when no rule matches, where links with no source app open, and a line naming the app the last link came from, for example "Last link came from: Slack (com.tinyspeck.slackmacgap)", so the person can copy its bundle identifier into a rule.
  The line updates as links arrive, also while the editor is open.
- Destinations are offered by name: each Space of the open windows, each profile, Little Arc and the most recent window; a destination that no longer exists shows as missing.
- Rules that can never match (an empty or invalid text, no condition, or hidden by an earlier rule) are listed under the controls with the reason.
- Every change is saved at once.

## Edge cases

- Surrounding spaces and newlines in a link are ignored before matching.
- A link with no sender and no matching URL rule goes to the "no source" destination when one is set, else to the default.
- Two rules with the same conditions: the first wins and the second is reported as hidden.
- An unknown destination kind in saved data makes loading fail instead of picking a guess.

## Acceptance checks

- Run `make e2e`: `PASS links.intake: early=queued sender=bundle` shows links delivered as get URL requests at the earliest moment kept in order until the window opened, later links (a burst with malformed ones mixed in) opening at once in the Space on screen, a sent request recording Bow as its source app, an unsent one recording none, and Bow's renderer helper counting as Bow.
- `PASS link.ignored` shows a get URL request that is not the run's own opening nothing in an e2e run.
- `PASS routing: github.com->work slack->personal fallback=little-arc` shows the example below end to end, with links sent as real get URL requests and Bow's own sender standing in for Slack and Mail.
- `PASS routing.helper` shows a link from Bow's renderer helper routed by a rule on Bow's bundle identifier.
- `PASS routing.first_request` shows a routed link creating exactly one page, in the routed Space's profile, which loaded once.
- `PASS routing.editor` shows the editor listing the rules and the default, naming Slack as the last source when a link arrives while it is open, and Move Down saving the new order.
- `PASS routing.persist` shows saved rules read back the same by a new service on the same folder.

1. With rules "address contains github.com" to Work and "source app Slack" to Personal, and the default Little Arc: a github.com link goes to Work, a link from Slack goes to Personal, a link from anywhere else goes to Little Arc.
2. A link from Slack that is also a github.com link goes to Work, because that rule is first.
3. A link from a helper process mapped to Slack is routed as if Slack sent it.
4. A rule whose expression is invalid never matches and is reported as unusable.
5. Saved data with a newer version fails to load.

## Out of scope

- Dragging rules to reorder them (Move Up and Move Down do it).
- A settings window holding the editor and the Little Arc setting.
- Routing links opened inside Bow (a click in a page), which follow the page's own link behavior instead.
