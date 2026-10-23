# Split view

## Summary

Split view shows two to four tabs side by side in one window, so a person can compare pages or keep one in sight while working in another.
How a split is saved in the sidebar is in `sidebar-store.md`; this spec covers how the window shows it.

## Behavior

### Panes in the window

- The page area shows one to four panes side by side, each showing one tab, with a thin divider between neighbours.
- With one pane the page area looks and behaves exactly as a window without split view.
- One pane has focus and is outlined in the accent color; its tab is the window's active tab, so the sidebar highlight, the window title, the toolbar, find and the keyboard all follow it.
- Clicking into a pane gives it focus before the page handles the click.
- Selecting, in the sidebar, the tab of a pane that is on screen moves focus to that pane; selecting any other tab shows that tab alone.
- Dragging a divider resizes the two panes beside it; each pane keeps at least a tenth of the width.
- Resizing the window, or entering full screen, keeps each pane's share of the width.
- A view floating over the page (such as Peek's card) sits above every pane.

### Split views in the sidebar

- A split view is a sidebar item holding two to four tabs (`sidebar-store.md`).
  Selecting one of its tabs, or clicking the split's row (which selects its focused tab), shows all of its tabs as panes with that tab focused.
  Selecting any other tab shows that tab alone; selecting the split again brings its panes back with the pane that last had focus.
- The focused pane is saved in the split whenever the person focuses a pane (a click into it, its row), so it survives switching tabs, switching Spaces and relaunching.
- Dragging a divider saves each pane's share of the width in the split; the split shows at those widths after a relaunch.
- A tab row's context menu offers "Open in Split View" while another tab is selected: the clicked tab joins the selected tab's split as its last pane, or the two become a new split, and the clicked tab gets focus.
  It is offered only where the split rules allow it (same section, no Favorites, at most four panes).
- View > Add Split View (Cmd+Shift+plus, Arc's shortcut) opens a new tab as a pane beside the selected tab, focused, in a new split or in the selected tab's split.
  It is available when the selected tab sits in its Space's today section and its split has room.
- Each pane shows a small close button at its top trailing corner while a split shows.
  It takes that pane out of the split and leaves its tab as a plain tab right after the split; a split left with one tab turns back into that tab, shown alone.
  No tab closes and no page is asked to leave.
- A split's row and each of its tabs offer "Separate All Tabs" (Arc's wording), which turns the split back into its tabs in its place, in pane order; the selected tab is shown alone.
  A tab inside a split also offers "Remove from Split View", as its pane's close button does.
- A split saved with no tabs is removed when the sidebar is read, and one saved with one tab becomes that plain tab in its place; neither is ever shown.

## Edge cases

- Closing the focused pane's tab gives focus to the pane before it (the one after it when it was first); the other panes stay on screen and share its width.
- Closing a pane's tab that leaves one pane returns the page area to a single view of the remaining tab.
- A pane's tab that crashes, or a pane whose page is still loading, keeps its pane.
- A tab shown in any pane counts as visible, so it is never unloaded to save memory.
- A pane whose tab closes or unloads for another reason leaves, and the others share its width.
- A pinned pane's tab closed from its row unloads and stays in the split, but leaves the screen; selecting that tab brings the whole split back.
- A press into an unfocused pane while the window shows a sheet changes nothing.
- When the panes collapse to one while the keyboard was in a pane, the remaining page keeps the keyboard.
- Quitting or closing the window with a split on screen loads nothing; the split shows again when its tab is selected after relaunch.
- A split inside a closed folder still shows when one of its tabs is selected.

## Acceptance checks

1. Open tabs A to D and show all four as panes with C focused: four equal panes show A, B, C and D in order, C is outlined, selected and active.
2. Show A and C with A focused, then focus the second pane: C becomes the selected and active tab, is outlined, and its page has the keyboard.
3. Click into the first pane: A is focused, selected and active again.
4. Place an overlay over the page area, then change the panes: the overlay stays in front.
5. Close A while it has focus: C (the other pane, not B, A's neighbour in the sidebar) is shown alone, filling the page area, selected and active.
6. With A selected, choose B's "Open in Split View": the today section holds one split item of A and B, shown as two panes with B focused.
7. With only A, choose View > Add Split View: a new tab shows as a second pane beside A, focused, saved as one split.
8. Drag the divider of a split of A and B to 70%: the split saves 0.7 and 0.3, and after a relaunch shows at that share.
9. Press A's pane close button with the keyboard in B: A and B are plain tabs, B shows alone and keeps the keyboard.
10. With a sheet up, click pane A: B stays active; then "Separate All Tabs" on the split's row leaves tabs A and B in its place, B shown alone.
11. Open a sidebar file holding a split with no tabs and a split with only B: neither shows, and B is a plain tab.
12. Focus A in a split of A and B, select C, then click the split's row: both panes come back with A focused.

## Out of scope

- Stacked (top and bottom) panes: a split saved as stacked (imported from Arc) shows side by side, and Arc's "Add Top Split" and "Add Bottom Split" are not offered yet.
- Making a split by dragging a tab into the page area, and the command bar's "Add Left/Right Split" commands.
- Add Split View opens the new tab on the new tab page rather than in the command bar as Arc does.
- Permission prompts, the crashed page message, the find bar and page dialogs follow the focused pane only.
- Peek itself; only the seam it uses is covered here.
