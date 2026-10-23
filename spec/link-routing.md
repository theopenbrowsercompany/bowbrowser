# Link routing (Air Traffic Control)

## Summary

Link routing decides where a link opened from outside the browser goes, so work links land in the work Space and personal links never open in a work account.
People set it up once as an ordered list of rules plus a default.

## Behavior

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

1. With rules "address contains github.com" to Work and "source app Slack" to Personal, and the default Little Arc: a github.com link goes to Work, a link from Slack goes to Personal, a link from anywhere else goes to Little Arc.
2. A link from Slack that is also a github.com link goes to Work, because that rule is first.
3. A link from a helper process mapped to Slack is routed as if Slack sent it.
4. A rule whose expression is invalid never matches and is reported as unusable.
5. Saved data with a newer version fails to load.

## Out of scope

- Reading the sender of a link from the system, and routing before the tab's first request: they need the app and are separate work.
- The rule editor and showing the detected source app.
- The Spaces, profiles, Little Arc and windows that destinations point to.
- The `make e2e` line for routing.
