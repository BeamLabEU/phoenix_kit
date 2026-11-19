# Claude Review — PR #1046

**Reviewer:** Claude Opus 5.5, with codex (GPT-6.1) and zai (GLM-5.3)
**PR:** A people picker for every module, notification settings that save as you flip, which line sent a notification, a quoted message under it, avatar letters from the name (mdon)
**Reviewed:** 2026-11-19

The author's own review before opening, for core's part of the boss's fourth Projects list
(tim-dev, 2026-11-18). The `lib/` and admin-JS diff went to codex and zai with numbered
questions; codex re-reviewed the fixes. Every finding was checked against the code first; each
fix has a test where one could pin it.

## Findings

### BUG - MEDIUM — a second tab could switch a preference back on (fixed)
Saving on every change posted the WHOLE form, and the in-app write filled unposted keys from
the page's own copy: tab A turns "Posts" off, tab B (opened earlier) flips "Tasks", and B's
still-checked "Posts" was written back (codex, re-review). A change now saves only its
`_target`, and the in-app write merges only posted keys over what is stored now. Test: "a
second tab showing an older state writes back only the switch it flips".

### BUG - MEDIUM — LiveView form recovery could replay old switches (fixed)
On reconnect the form's old snapshot was replayed as a change (codex). The form is
`phx-auto-recover="ignore"`.

### BUG - LOW — switches under a master that is off were still reachable by keyboard (fixed)
`pointer-events-none` only; Tab + Space flipped them and posted (codex). They, and their hidden
"false", are `disabled` while the master is off: not posted, the stored value stands.

### BUG - LOW — a source could hand back a key it cannot describe (fixed)
`pick/2` / `confirm/2` returning another key added it unchecked (codex). `add_described/2`
describes it first.

### BUG - LOW — a pick refused by `max` still changed Recent and messaged the parent (fixed)
(codex, zai) `add/2` does nothing when the list did not change.

### BUG - LOW — stale ticks and chips after the parent changes the list (fixed)
A parent passing a different list (a refusal, its own change) left listed rows' ticks as they
were, and a chip described as "No longer listed" stayed so (codex, zai). `update/2` re-inserts
the changed keys' listed rows and re-describes chips without a row; a changed viewer resets
Recent and "Add me".

### BUG - LOW — option DOM ids could collide (fixed)
`"opt-#{kind}-#{uuid}"` is the same for `team-a`/`b` and `team`/`a-b` (codex). The id encodes
the key.

### BUG - LOW — two anchors could collide (fixed)
`notif-` + key with `.` → `-` made `comments.replies` and a type `comments-replies` one anchor
(codex). The anchor keeps the dot.

### BUG - LOW — "Add me" for a viewer the source cannot describe did nothing (fixed)
(zai) The button shows only when the viewer's key describes.

### NITPICK — an empty `name` stopped the avatar's fallback (fixed)
`%{name: "", username: "anna.kask"}` showed "?" (codex). Blank values are skipped.

## Checked and not changed

- **A quote's markdown link in the email** (codex, zai): email placeholders are substituted
  AFTER the markdown is rendered, and `{{…}}` values are escaped (`PhoenixKit.Email.Markdown`),
  so `[label](url)` in a quote arrives as text.
- **The parent ignoring a `:changed` message** leaves the optimistic chip (and a surrounding
  form's hidden input): documented — a parent that refuses hands the list back.
- **A form named `<id>-no-form`** on the page would own the search input (codex): needs the
  host to pick that exact id.
- **Paste from the right-click menu** does not search until the next key press (codex):
  `phx-keyup` only; an input outside every form cannot carry `phx-change`.
- **Viewer cleared to nil** keeps the previous one (codex): no caller clears the viewer.
- **The email text part collapses 3+ newlines** (zai): only spacing; paragraphs stay
  paragraphs.
- **Row menus and item 16** (the coordinator): `table_row_menu` was already in the top layer
  (portal + `popover="manual"`), so a card cannot cover it; switching to `popover="auto"` would
  bypass the hook's close bookkeeping. `_open` now closes any other open row menu.

## Verification

- `mix precommit`: exit 0 on the final tree.
- Full suite: see the PR body.
