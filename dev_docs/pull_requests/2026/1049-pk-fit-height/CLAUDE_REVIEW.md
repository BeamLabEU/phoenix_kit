# Claude Review — PR #1049

**Reviewer:** Claude Opus 5.5
**PR:** Add PkFitHeight: an overlay never taller than the room left in its scrolling ancestor (timujinne)
**Reviewed:** 2026-11-19 (merged into `main` the same day)

JavaScript only: a public hook in `phoenix_kit.js`, its tests, the public/admin inventory and the
size budget. Nothing in core uses it yet; the first user is the inbox compose window.

## Findings

### IMPROVEMENT - MEDIUM — the size budget left 123 bytes (fixed)

The PR raised the budget in `admin_split.test.cjs` from 292 to 296 KiB (303 104 B). With the hook,
`phoenix_kit.js` is 302 981 B, so 123 bytes were left: the next one-line fix to any public hook
would fail the test, and the failure would point at that unrelated change. The budget is now
298 KiB (~2.1 KB of room). That is still far below the smallest admin hook it is meant to catch
(AvatarCrop, 13 158 B). #1048 (`<.resizable_modal>`, draft) adds another public hook and will need
its own raise when it lands.

### NITPICK — the first frame of a revealed overlay is painted at full height (not changed)

A ResizeObserver or scroll callback only schedules a measurement for the next animation frame.
So an overlay mounted hidden and shown on the client is painted once before its height is limited.
Measuring inside the callback would resize the element it observes and raise "ResizeObserver
loop completed with undelivered notifications". The PR documents this trade-off in the hook's
comment, and it is the right call.

### NITPICK — the boundary is found once, at mount (not changed)

`_boundary` is computed in `mounted()`. An element that a patch moves under a different scroller
keeps measuring against the old one. LiveView replaces a hook element that changes parent rather
than moving it, so this is theoretical. A fresh `_scroller()` on every measure would cost one
`getComputedStyle` per ancestor per frame, which is not worth it.

## Checked

- **Public placement.** A generic overlay primitive, like `ViewportPopover` and `PkDialog`: a
  page outside the admin area can render it. Listed in `PUBLIC` (39 + 41 = 80 hooks), in
  `guides/public-and-admin-javascript.md`, and not in `ADMIN_HOOKS`.
- **No feedback loop.** Each measurement clears the inline value and sets it again in the same
  task, so the observer sees only the final size. A second measurement of the same room writes the
  same value, and the observer stops.
- **Own ceiling.** The class `max-height` is read with the inline value cleared, so the hook
  never reads back its own earlier value as a cap. `none` and percentages are not caps
  (`vh`/`rem` compute to px and are). A cap below `data-fit-min` wins over the minimum.
- **Scroll filter.** Capture phase; the element's own scrolling (it or a descendant) is ignored;
  the window, the document and a missing target count as the page's scroll and do not throw.
- **Teardown.** `destroyed()` removes both listeners (the scroll one with matching `capture`),
  disconnects the observer and cancels a pending frame.
- **Gate.** `node --test test/js/*.test.cjs`: 912 of 912 on the merge into current `main`;
  `node --check` on the bundle; `mix precommit`. Not checked in a real browser here (the PR
  reports a headless Chrome check on a host application).
