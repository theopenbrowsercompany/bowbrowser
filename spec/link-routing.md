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
- Until routing rules are wired in, every link opens in a new tab of the most recently used window, in the Space on screen there, as Arc does without rules.
  The source app goes with the link to where it opens, for the rules to use.
- Links that arrive before Bow can open them are kept, in the order they came, and open once the first window is open.
  In practice the engine is ready before the system hands Bow its first link, so links that launch Bow open right away.
- Links that arrive while Bow is quitting are dropped, so quitting never opens a new window; if a page cancels the quit, later links open again.
- When launch refuses to start (the sidebar cannot be opened), kept links and links that arrive while its alert is open are dropped.
- A burst of links opens every one, each in its own tab, in the order they came.
- Links from other apps never open in an e2e or smoke run: they are meant for the person's own Bow.
  The e2e run delivers its own links through a test only path, so the real path stays closed.

### Routing rules

- The routing list is ordered rules plus one default destination.
  The first rule that matches a link decides where it opens; if none matches, the default decides.
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
- The saved list carries a version.
  A list saved by a newer version of the app is refused rather than partly read.
- When the app is not yet wired to the sender or the editor, the pieces below stay open, and routing in BowCore is exercised by unit tests only.

## Edge cases

- Surrounding spaces and newlines in a link are ignored before matching.
- A link with no sender and no matching URL rule goes to the default.
- Two rules with the same conditions: the first wins and the second is reported as hidden.
- An unknown destination kind in saved data makes loading fail instead of picking a guess.

## Acceptance checks

- Run `make e2e`: `PASS links.intake: early=queued sender=bundle` shows links delivered as get URL requests at the earliest moment kept in order until the window opened, later links (a burst with malformed ones mixed in) opening at once in the Space on screen, a sent request recording Bow as its source app, an unsent one recording none, and Bow's renderer helper counting as Bow.
- `PASS link.ignored` shows a get URL request that is not the run's own opening nothing in an e2e run.

1. With rules "address contains github.com" to Work and "source app Slack" to Personal, and the default Little Arc: a github.com link goes to Work, a link from Slack goes to Personal, a link from anywhere else goes to Little Arc.
2. A link from Slack that is also a github.com link goes to Work, because that rule is first.
3. A link from a helper process mapped to Slack is routed as if Slack sent it.
4. A rule whose expression is invalid never matches and is reported as unusable.
5. Saved data with a newer version fails to load.

## Out of scope

- Routing before the tab's first request, and applying the rules to received links: separate work.
- The rule editor and showing the detected source app.
- The Spaces, profiles, Little Arc and windows that destinations point to.
- The `make e2e` line for routing rules.
