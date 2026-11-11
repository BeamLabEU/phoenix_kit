# PR #1024 — Add an opt-in overflow menu to nav_tabs

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve; one bug and one nitpick fixed, two nitpicks left on record

Adds `overflow={:menu}` to `<.nav_tabs>`: the strip stays one row and the tabs that do not fit move into a "⋯"
dropdown driven by the `NavTabsOverflow` hook. The server renders every tab twice (strip tab + plain menu item); the
hook measures, toggles `hidden` on each pair, and forwards a pick to the strip tab with `click()`. `:wrap` (the
default) is unchanged and no core page opts in yet.

Checked and fine: the strip tab stays the only element carrying link / `phx-*` attributes, so `tab.click()` is
handled by LiveView exactly as a direct click and the hook's own delegated click listener ignores it (it only acts
on `[data-nav-menu] [role='menuitem']`). A LiveView patch resets the JS-set `hidden` classes and the menu's inline
position to the server markup; the MutationObserver (a microtask, so before paint) and `updated()` re-run `sync()`,
which re-opens and re-positions an open menu. `navTabsHidden` keeps order, reserves room for a late active tab and
lets the active tab alone truncate. The ResizeObserver is coalesced into one frame and `sync()` is idempotent, so a
content-sized parent settles instead of looping. "More tabs" is translated in all nine locales.

## Findings

### BUG - MEDIUM — Escape in the open menu also closed a dialog around the strip (fixed)

The hook's `keydown` listener on `document` closed the menu on Escape but neither prevented the default nor stopped
propagation. A native `<dialog>`'s cancel is that keydown's default action, and a `phx-window-keydown` /
`phx-key="Escape"` modal listens on `window` after `document` — so with a tab strip inside either, one Escape closed
the menu *and* the whole dialog. `DateInput` already guards its popup against exactly this ("the event must not reach
a PkDialog / modal around the field"). Strips inside framed containers (a picker's filter row) are the use case
`:plain` exists for, so this is reachable as soon as a caller opts in.

Fixed: the Escape branch (only reached while this menu is open) now calls `preventDefault()` and
`stopPropagation()`. With the menu closed Escape is left alone. Test added in
`test/js/nav_tabs_overflow.test.cjs` (fails on the old code).

### NITPICK — redundant `assign(:id, id)` (fixed)

`nav_tabs/1`'s `:menu` clause re-assigned `:id` to the value it had just read from the assigns. Removed.

### NITPICK — the "⋯" button is a non-tab child of `role="tablist"` (not fixed)

ARIA expects only `tab` children in a tablist, so an a11y linter (axe `aria-required-children`) can flag the "⋯"
button. The trailing slot in `:wrap` mode has had the same shape since it was added. The structure is forced by
daisyUI, which styles a tab only as a direct child of `.tabs`; moving `role="tablist"` off `.tabs` onto an inner
element would break that. Left as is.

### NITPICK — neighbours are observed as they were at mount (not fixed)

The ResizeObserver watches `previousElementSibling` / `nextElementSibling` captured in `mounted()`; a sibling
inserted later by a patch is not observed. Only matters for a content-sized strip whose new neighbour changes size
on its own; the parent is still observed, and the moduledoc already states the grandparent limit. Not worth
re-wiring observers on every `updated()`.
