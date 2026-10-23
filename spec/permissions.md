# Site permissions

## Summary

When a website asks to use the camera, microphone, location, notifications, the clipboard or another protected feature, Bow asks the person in its own prompt and remembers the answer for that site.
Video calls, maps and web notifications work once allowed, and a site that was blocked stays blocked without asking again.

## Behavior

- A page asks to use something that needs permission: a small prompt appears at the top leading corner of the page, naming the site and what it wants, for example "meet.example.com wants to use your camera and microphone".
- The prompt offers Block and Allow.
  Allow grants everything the page asked for in that request; Block refuses all of it.
- The answer is remembered for the site (its scheme, host and port) in the current profile.
  The next time that site asks for the same thing, Bow answers without a prompt: allowed stays allowed, and blocked stays blocked.
- A request that mixes kinds is allowed without a prompt only when every kind was allowed before, and refused without a prompt when any kind was blocked before; otherwise Bow asks.
- Answers belong to one profile.
  The same site in another Space with a different profile asks again, also in the same window: each tab reads and writes the answers of the profile it runs in.
- Answers in a profile kept on disk survive a restart; answers in an in-memory profile go away with it.
- Pages also see the remembered answer when they check their permission state (for example through the Permissions API).
- Screen sharing always asks, because the person picks what to share each time.
- Storage access for embedded content always asks, because it belongs to one embedded site under one top level site.
- The prompt's close button dismisses it without an answer: nothing is granted or remembered, and the page may ask again.
- Neither Allow nor Block is a default button, so pressing Return never answers a prompt.
- The first time an allowed site actually uses the camera, microphone or location, macOS may ask once whether Bow itself may use it; its text explains that only websites the person allows can use them.

## Edge cases

- Several requests at once wait in order; the prompt shows one at a time for the tab on screen.
- Switching to another tab hides the prompt and shows that tab's own request, if it has one; switching back shows it again.
- Closing the tab, or the tab leaving the page that asked, dismisses its waiting requests: nothing is granted or remembered, and the page may ask again.
- When several waiting requests come from the same site, answering one also answers the others it covers, in every window of the profile.
- A page with no web origin (a local file, `about:` or `data:` page) is asked every time and nothing is remembered for it.
- A damaged permissions file is set aside and Bow starts with no remembered answers, so it asks again rather than granting anything.
- Popup windows opened by pages keep the engine's default answer and show no prompt.

## Acceptance checks

1. Open a page that calls `navigator.mediaDevices.getUserMedia({video: true})`: a prompt reading "<site> wants to use your camera" appears at the top of the page.
2. Press Allow: the page receives a live camera track.
3. Call `getUserMedia` again on the same site: no prompt appears and the page receives a track; `navigator.permissions.query({name: "camera"})` reports `granted`.
4. Quit and reopen Bow, then open the same site in the same profile and ask again: no prompt appears.
5. Open the same page in a Space with another profile and ask: the prompt appears again; press Block and the page gets `NotAllowedError`, and asking again is refused without a prompt.
6. `make e2e E2E=permissions.prompt` prints `PASS permissions.prompt: camera=asked allow=granted`.
7. `make e2e E2E=permissions.per_profile` prints `PASS permissions.per_profile: work=granted personal=asked`: in one window, the camera allowed in a work Space's tab is still asked for in a personal Space's tab.

## Out of scope

- A settings screen to review or reset remembered answers per site.
- Answers that last only one visit ("allow this time") and quieter prompt styles for notifications.
- Showing that a site is using the camera or microphone right now.
- Prompts inside popup windows opened by pages (see `popups.md`).
