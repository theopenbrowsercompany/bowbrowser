# Split view

## Summary

Split view shows two to four tabs side by side in one window, so a person can compare pages or keep one in sight while working in another.
How a split is saved in the sidebar is in `sidebar-store.md`; this spec covers how the window shows it.

## Behavior

### Panes in the window

- The page area shows one to four panes, each showing one tab, with a thin divider between neighbours.
  A split lays its panes out side by side (Arc's horizontal split view) or stacked top to bottom (Arc's vertical split view), each the full width or height of the page area.
- With one pane the page area looks and behaves exactly as a window without split view.
- One pane has focus and is outlined in the accent color; its tab is the window's active tab, so the sidebar highlight, the window title, the toolbar, find and the keyboard all follow it.
- Clicking into a pane gives it focus before the page handles the click.
- Selecting, in the sidebar, the tab of a pane that is on screen moves focus to that pane; selecting any other tab shows that tab alone.
- Dragging a divider resizes the two panes beside it; each pane keeps at least a tenth of the width (of the height when stacked).
- Resizing the window, or entering full screen, keeps each pane's share.
- A view floating over the page (such as Peek's card) sits above every pane.
- Each pane keeps its own page UI, over that pane only, whether it has focus or not:
  - a permission prompt from a pane's page shows at the top leading corner of that pane, and each pane can show its own at once;
  - a pane whose page crashed shows "This page crashed" with Reload over that pane only, and the other panes stay usable;
  - the find bar opens at the top trailing corner of the focused pane, searches that pane's page, and closes when another pane takes focus;
  - an alert, confirm or prompt from any pane on screen comes up at once as a sheet dropping from the top of that pane, centered on it; the window has one sheet at a time, so a dialog from another pane waits for it, unanswered, and comes up next.

### Split views in the sidebar

- A split view is a sidebar item holding two to four tabs (`sidebar-store.md`).
  Selecting one of its tabs, or clicking the split's row (which selects its focused tab), shows all of its tabs as panes with that tab focused.
  Selecting any other tab shows that tab alone; selecting the split again brings its panes back with the pane that last had focus.
- The focused pane is saved in the split whenever the person focuses a pane (a click into it, its row), so it survives switching tabs, switching Spaces and relaunching.
- Letting go of a dragged divider saves each pane's share in the split, once per drag and never on every step of it; the split shows at those shares after a relaunch.
  The split's layout (side by side or stacked) is saved with it.
- A tab row's context menu offers "Open in Split View" while another tab is selected: the clicked tab joins the selected tab's split as its last pane, or the two become a new split, and the clicked tab gets focus.
  It is offered only where the split rules allow it (same section, no Favorites, at most four panes).
- View > Add Split View (Cmd+Shift+plus, Arc's shortcut) opens a new tab as a pane beside the selected tab, focused, in a new side by side split or as the last pane of the selected tab's split.
- View > Add Top Split and Add Bottom Split (Arc's names, with no shortcut) open a new tab as a pane above or below, focused: in a new stacked split, or as the first or last pane of the selected tab's stacked split.
  They are unavailable while the selected tab is in a side by side split, since a split has one layout.
- All three work from a tab in today, in a folder or in the pinned section, as Arc allows: a new split takes the selected tab's place in its section, and the new tab joins that section (beside a pinned tab it is pinned too).
  A new pinned pane has no pinned address while it shows the new tab page: the first page the person goes to in it becomes its pinned address, as pinning a page does, and from then on browsing never changes it.
  They are unavailable for a Favorite and when the split has four panes.
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
13. With only A, choose Add Bottom Split, then Add Top Split: one stacked split shows C, A and D top to bottom, each the full width.
14. Press on the divider of a split of A and B and move it to 60% then 70%: the saved shares stay 0.5 while the panes follow; letting go saves 0.7 and 0.3.
15. With pinned tab A selected, choose Add Split View: a split of A and the new tab takes A's place in the pinned section. Go to D in the new pane: D is its pinned address, with no Back to Pinned URL, and after a relaunch the pane comes back on D.
16. Show A and B with A focused: B's camera request shows its prompt at the top of B's pane, and closing B takes it away.
17. Crash B's page: "This page crashed" covers B's pane only, A keeps focus, and B's Reload brings it back.
18. With A focused on the left, open the find bar: it sits at A's pane's top trailing corner; focusing B closes it.
19. A confirm from B comes up at once as a sheet centered on B's pane with A still focused; closing B with a dialog up takes the sheet down.

## Out of scope

- Mixing layouts in one split (a pane beside two stacked ones): a split is side by side or stacked, so Add Top Split and Add Bottom Split are unavailable in a side by side split.
- Making a split by dragging a tab into the page area, and the command bar's "Add Left/Right/Top/Bottom Split" commands.
- Add Split View opens the new tab on the new tab page rather than in the command bar as Arc does.
- Sign in and certificate error sheets still drop from the top of the window, not of their pane.
- Peek itself; only the seam it uses is covered here.
