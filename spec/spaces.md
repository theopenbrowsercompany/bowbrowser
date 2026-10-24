# Spaces

## Summary

Spaces separate contexts such as work and personal.
Each Space has its own pinned tabs and tabs, and one window shows one Space at a time, so switching never opens another window.

## Behavior

- A window starts with one Space.
  The person can create more, rename them and delete them.
- The "+" button at the end of the Space switcher and View > Spaces > New Space create a Space.
- A new Space is empty, goes at the end of the list and comes on screen right away.
  It is called "Space 2" when it is the second Space, "Space 3" when it is the third, and so on, until the person renames it.
  Its name is trimmed and cannot be empty; two Spaces may share a name.
- View > Spaces > Rename Space, double-clicking the Space name above its tabs, or Rename Space in the context menu of a Space's name or icon asks for the new name in a sheet with the current name filled in.
  Rename saves it; Cancel, or an empty name, keeps the old one.
- Renaming a Space changes only its name.
  Its tabs stay where they are.
- View > Spaces > Delete Space deletes the Space on screen, and Delete Space in the context menu of a Space's icon deletes that Space.
  A Space with tabs asks first in a sheet that says how many tabs close with it; Delete goes ahead and Cancel keeps everything.
  An empty Space goes at once.
- Deleting a Space closes its pinned tabs and tabs together with it.
  If it was on screen, its neighbour comes on screen (the next Space, or the previous one when it was last).
- The sidebar shows the name of the Space on screen below the Favorites and above its tabs, with its emoji in front when it has one.
- The footer of the sidebar is the Space switcher: one icon per Space in order, with the Space on screen highlighted, and the "+" button at its end.
  A Space's icon is its emoji or symbol; a Space with no icon shows a small dot.
  Hovering an icon shows the Space's name, and clicking it shows that Space.
- Switching shows only the tabs of the Space you switch to, pinned tabs first, then the others.
  Favorites stay visible in every Space of the same profile (see `sidebar-store.md`).
- Ctrl+1 through Ctrl+9 show the first through ninth Space.
  A number with no Space behind it does nothing.
  View > Spaces lists them under each Space's name, with a check by the one on screen, and a number with no Space is greyed out.
- Cmd+Option+Right and Cmd+Option+Left (View > Spaces > Next Space and Previous Space) show the next and previous Space.
  They stop at the last and first Space; they do not wrap around.
- A two finger swipe sideways in the sidebar shows the previous or next Space, moving the Spaces the way the scroll direction setting moves content sideways: with natural scrolling (the default), moving the fingers left shows the next Space, and moving them right the previous one.
  A short swipe does nothing.
  The swipe stops at the first and last Space; it does not wrap around.
- Whenever another Space comes on screen, by the switcher, a shortcut, a swipe, creating or deleting, the sidebar's tabs slide out towards the side the old Space sits on while the new Space's tabs slide in.
  With Reduce Motion on, they change without the slide.
- Each Space remembers the tab that was selected when you left it and selects it again when you come back.
  A Space you have not used yet selects its first tab, or shows no selected tab when it has none.
  If the selected tab is a Favorite, it stays selected while you switch.
- Selecting a tab that lives in another Space (for example from the command bar) first shows that Space.
- A tab, folder or split can be moved to any Space, into its pinned tabs or its tabs, with everything inside it.
  The Space on screen stays on screen.
  If the moved tab was the selected one, that Space selects its own remembered or first tab instead.
- Every Space has an icon and a color theme.
  The icon is one emoji or the name of a symbol, or none; a new Space has none.
  The theme is a primary color given as a hex value such as `#3B5BDB`; a new Space uses the default theme, a neutral gray blue.
  Both are set from the Space menu and can be removed, which goes back to no icon and the default theme.
- An icon must be exactly one emoji (a flag, a skin toned hand or a family counts as one; a digit, a letter or two emoji do not), or a symbol name of lowercase letters, digits, dots, dashes and underscores that starts with a letter.
  A color must be `#RRGGBB`, or the short form `#RGB`, with or without the `#`, in either case.
  It is saved as capitals, `#RRGGBB`.
  Anything else is refused with a message and the Space keeps what it had.
- The context menu of the Space name above its tabs is the Space menu.
  Its Theme submenu offers Default and the colors Blue `#3B5BDB`, Jam `#E8743B`, Apricot `#FFC08A`, Cocoa `#7A5A48`, Green `#2F7D4F` and Brick `#B84E1B`, each with a small swatch, with a check by the Space's own; Default removes the theme.
  Change Icon… asks for one emoji in a sheet with the current emoji filled in (Edit > Emoji & Symbols lists them); an empty field changes nothing, and anything but one emoji is refused with a message.
  Remove Icon removes the icon, and is greyed out while the Space has none.
- The theme of the Space on screen decides the tint of the sidebar and window background.
  Switching Spaces switches the tint, and a Space with no theme tints with the default one.
  Setting an icon or theme changes nothing else about the Space.
- A Space's theme gives the whole chrome a palette, as Arc derives one from a theme color (the roles are named at https://arc.net/colors.html: background, backgroundExtra, foregroundPrimary, foregroundSecondary, foregroundTertiary, focus, hover, title and subtitle).
  `SpacePalette` gives, for a theme and light or dark appearance, background, backgroundExtra, title, subtitle, foregroundPrimary, foregroundSecondary, foregroundTertiary, hover, selectedFill, tileFill, fieldFill, divider and focus, plus a backdrop opacity.
  The sidebar and the frame around the page are the background; rows, tiles, the address field and dividers take their fills from the same palette, so none of them stays cream in a themed Space.
  Every neutral keeps the theme's hue.
- The palette keeps text readable in every Space and appearance: primary text and the title are at least 7:1 against the background, secondary text and the subtitle at least 4.5:1, and the focus color at least 3:1.
- The default theme returns the brand kit colors exactly: background `#FFF3E6` in light and `#2A1710` in dark, title `#3A1F14` in light and `#FFF3E6` in dark, and no backdrop, so an unthemed Space looks as it always did.
  Switching between light and dark keeps the theme and takes that appearance's palette.
- Until the sidebar, tiles and field read their fills from the palette, the app still draws the earlier wash (12 percent of the theme color over the Frame color, `#E7E1E5` light and `#2C1F28` dark for Blue); the palette is the rule and the wash is replaced as each surface moves over.
- When the tint changes (another Space comes on screen, or the Space on screen gets another theme) it fades to the new one in a fifth of a second.
  A change during a fade fades on from the color shown then, so quick switches end on the right tint.
  With Reduce Motion on, it changes at once.
- Every window showing the Space follows a change to its theme.
- Every Space belongs to a profile, which decides its logins and cookies.
  For now every Space uses the default profile; choosing another profile is a separate feature.

## Edge cases

- The last Space cannot be deleted: a window always has at least one.
  Delete Space is greyed out in the menus while only one Space is left.
- Only one question is asked at a time: Rename Space and Delete Space are greyed out in the menu bar while the window shows a sheet.
- A new Space whose number is already a Space's name takes the next free number, so deleting "Space 2" of "Space 2" and "Space 3" and creating one gives "Space 4".
- Switching to the Space already on screen changes nothing.
- A Space with no tabs shows an empty sidebar section and no selected tab.
- The list of Spaces, their order, the Space on screen and the tab each Space remembers are saved with the rest of the sidebar, so quitting and relaunching shows the same Space with the same tabs.
- A sidebar saved before Spaces had profiles opens with every Space on the default profile.
- A sidebar saved before icons and themes opens with no icons and the default theme on every Space.
  An icon or theme in the file that cannot be read counts as not set; the Space itself is kept.
- Closing the last tab of a Space does not delete the Space or switch away from it.

## Acceptance checks

1. Start with the one Space, rename it "work", then create "personal": "personal" is on screen and empty, and the list reads work, personal.
2. Open tabs A and B in "work", switch to "personal" and open tab C: the sidebar shows only C, and switching back to "work" shows only A and B with B selected again.
3. With two Spaces, press Ctrl+2 then Ctrl+1: each press shows that Space. Press Ctrl+5: nothing changes.
4. Swipe two fingers toward the next Space on the last Space: nothing changes. Swipe back: the previous Space shows. The window count stays at one throughout.
5. Move tab B from "work" to "personal" while "work" is on screen: "work" stays on screen and selects A, and "personal" lists C then B.
6. Delete "work" while it is on screen: its tabs close, "personal" comes on screen, and the only Space left cannot be deleted.
7. Quit and relaunch: the same Spaces, order, on screen Space and tabs come back.
8. Set "work" to the emoji "💼" and the color `3b5bdb`: the Space reads icon "💼" and theme `#3B5BDB`, "personal" keeps no icon and the default theme, and with "work" on screen the active theme is `#3B5BDB`. Switching to "personal" makes it the default theme.
9. Try the icon "ab" or "1", the symbol "Bad Name" and the color "blue": each is refused and the Space is unchanged.
10. Quit and relaunch: the icon and theme come back. A sidebar saved without them opens with none.
11. Run `make e2e`: `spaces.switch` prints `PASS spaces.switch: windows=1 active=personal tabs=[C]`.
12. With one Space "work" holding tab A, click "+": "Space 2" is on screen, empty, named above its tabs and highlighted in the footer. Choose View > Spaces > New Space: "Space 3" is on screen.
13. Rename "Space 3" to " personal " in the sheet: it reads "personal" in the list and above its tabs.
14. Delete the empty "Space 2": no question is asked. Delete "work": the sheet asks first, Cancel keeps it, and Delete removes it with its tab. With only "personal" left, Delete Space is greyed out.
15. With "work" on screen, press Cmd+Option+Right twice and Cmd+Option+Left twice: personal, personal (the second press is greyed out), work, work.
16. Swipe towards the next Space, again on the last Space, a short swipe back, then a full swipe back: personal, personal, personal, work, in one window.
   `make e2e` drives the sidebar's swipe handler directly for this, since a real trackpad gesture cannot be synthesized.
17. With "work" on screen, choose Theme > Blue and Change Icon… with "💼" from its Space menu: the name reads "💼 work", the Space menu checks Blue, and the window background and sidebar fade to `#E7E1E5` (light) or `#2C1F28` (dark). Change Icon… with "ab" is refused with a message.
   Switching to the unthemed "personal" fades back to the Frame color, and Theme > Default on "work" removes its wash.
   `make e2e` prints `PASS spaces.theme_tint: work=#3B5BDB tint_matches=true`.

18. Drag tab A from the sidebar over the icon of another Space: the icon shows its ring. Drop it: the tab moves there, as in 5 (and as Move to Space does in `profiles.md`).
   Dropping a folder or a Favorite on an icon, or a tab on the icon of the Space it is in, is refused; moving the drag off an icon without a drop changes nothing.
   `make e2e` prints `PASS spaces.drop_move`, `PASS spaces.drop_other_profile` and `PASS spaces.drop_refuse`.

## Out of scope

- Reordering Spaces, choosing a Space's icon or theme from the switcher, and choosing a symbol icon from a menu.
- Choosing a profile for a Space, and moving a tab between Spaces of different profiles (see `profiles.md`).
- Gradients, light or dark overrides and other richer themes (a theme can later carry more than one color).
- Restoring or archiving the tabs of a deleted Space (see `sidebar-store.md` for archiving).
- Saving the sidebar itself (see `sidebar-store.md`).
