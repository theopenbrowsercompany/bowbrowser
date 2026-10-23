# Spaces

## Summary

Spaces separate contexts such as work and personal.
Each Space has its own pinned tabs and tabs, and one window shows one Space at a time, so switching never opens another window.

## Behavior

- A window starts with one Space.
  The person can create more, rename them and delete them.
- A new Space is empty, goes at the end of the list and comes on screen right away.
  Its name is trimmed and cannot be empty; two Spaces may share a name.
- Renaming a Space changes only its name.
  Its tabs stay where they are.
- Deleting a Space closes its pinned tabs and tabs together with it.
  If it was on screen, its neighbour comes on screen (the next Space, or the previous one when it was last).
- The sidebar shows the name of the Space on screen and a switcher listing every Space.
  Choosing one in the switcher shows that Space.
- Switching shows only the tabs of the Space you switch to, pinned tabs first, then the others.
  Favorites stay visible in every Space.
- Ctrl+1 through Ctrl+9 show the first through ninth Space.
  A number with no Space behind it does nothing.
- A two finger swipe sideways shows the previous or next Space.
  The swipe stops at the first and last Space; it does not wrap around.
- Each Space remembers the tab that was selected when you left it and selects it again when you come back.
  A Space you have not used yet selects its first tab, or shows no selected tab when it has none.
  If the selected tab is a Favorite, it stays selected while you switch.
- Selecting a tab that lives in another Space (for example from the command bar) first shows that Space.
- A tab, folder or split can be moved to any Space, into its pinned tabs or its tabs, with everything inside it.
  The Space on screen stays on screen.
  If the moved tab was the selected one, that Space selects its own remembered or first tab instead.
- Every Space belongs to a profile, which decides its logins and cookies.
  For now every Space uses the default profile; choosing another profile is a separate feature.

## Edge cases

- The last Space cannot be deleted: a window always has at least one.
- Switching to the Space already on screen changes nothing.
- A Space with no tabs shows an empty sidebar section and no selected tab.
- The list of Spaces, their order, the Space on screen and the tab each Space remembers are saved with the rest of the sidebar, so quitting and relaunching shows the same Space with the same tabs.
- A sidebar saved before Spaces had profiles opens with every Space on the default profile.
- Closing the last tab of a Space does not delete the Space or switch away from it.

## Acceptance checks

1. Start with the one Space, rename it "work", then create "personal": "personal" is on screen and empty, and the list reads work, personal.
2. Open tabs A and B in "work", switch to "personal" and open tab C: the sidebar shows only C, and switching back to "work" shows only A and B with B selected again.
3. With two Spaces, press Ctrl+2 then Ctrl+1: each press shows that Space. Press Ctrl+5: nothing changes.
4. Swipe two fingers toward the next Space on the last Space: nothing changes. Swipe back: the previous Space shows. The window count stays at one throughout.
5. Move tab B from "work" to "personal" while "work" is on screen: "work" stays on screen and selects A, and "personal" lists C then B.
6. Delete "work" while it is on screen: its tabs close, "personal" comes on screen, and the only Space left cannot be deleted.
7. Quit and relaunch: the same Spaces, order, on screen Space and tabs come back.
8. Run `make e2e`: `spaces.switch` prints `PASS spaces.switch: windows=1 active=personal tabs=[C]`.

## Out of scope

- How the sidebar draws Spaces, the switcher and the swipe animation.
- Choosing a profile for a Space, and confirming a move between Spaces of different profiles.
- Per Space icons, colors and themes.
- Restoring or archiving the tabs of a deleted Space (see `sidebar-store.md` for archiving).
- Saving the sidebar itself (see `sidebar-store.md`).
