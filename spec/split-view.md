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

## Edge cases

- Closing the focused pane's tab gives focus to the pane before it (the one after it when it was first); the other panes stay on screen and share its width.
- Closing a pane's tab that leaves one pane returns the page area to a single view of the remaining tab.
- A pane's tab that crashes, or a pane whose page is still loading, keeps its pane.
- A tab shown in any pane counts as visible, so it is never unloaded to save memory.
- A pane whose tab closes or unloads for another reason leaves, and the others share its width.

## Acceptance checks

1. Open tabs A to D and show all four as panes with C focused: four equal panes show A, B, C and D in order, C is outlined, selected and active.
2. Show A and C with A focused, then focus the second pane: C becomes the selected and active tab, is outlined, and its page has the keyboard.
3. Click into the first pane: A is focused, selected and active again.
4. Place an overlay over the page area, then change the panes: the overlay stays in front.
5. Close A while it has focus: C (the other pane, not B, A's neighbour in the sidebar) is shown alone, filling the page area, selected and active.

## Out of scope

- Creating, saving and separating splits from the sidebar, the command bar or a drag (the split view feature, which builds on the panes).
- Stacked (top and bottom) panes.
- Peek itself; only the seam it uses is covered here.
